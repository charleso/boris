{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Boris.Http.Api.Build (
    byId
  , list
  , queued
  , submit
  , heartbeat
  , acknowledge
  , cancel
  , byCommit
  , byProject
  , logOf
  , avow
  , disavow
  , complete
  , BuildError (..)
  , renderBuildError
  ) where


import           Control.Monad.IO.Class (MonadIO (..))

import           Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Time as Time

import           Boris.Core.Data
import           Boris.Http.Boot
import qualified Boris.Http.Api.Project as Project

import qualified Boris.Http.Service as Service
import           Boris.Http.Store.Data
import qualified Boris.Http.Store.Api as Store
import qualified Boris.Http.Store.Error as Store
import           Boris.Queue (Request (..), RequestBuild (..))

import           Data.Conduit (Source, (=$=))
import qualified Data.Conduit.List as Conduit

import           Jebediah.Data (Query (..), Following (..), Log (..))
import qualified Jebediah.Conduit as Jebediah

-- FIX MTH this shouldn't be needed once logging gets sorted
import           Mismi.Amazonka (Env)

import           P

import           System.IO (IO)

import           X.Control.Monad.Trans.Either (EitherT)

data BuildError =
    BuildStoreError Store.StoreError
  | BuildRegisterError Store.RegisterError
  | BuildConfigError Project.ConfigError
  | BuildServiceError Service.ServiceError

renderBuildError :: BuildError -> Text
renderBuildError err =
  case err of
    BuildStoreError e ->
      mconcat ["Build error via store backend: ", Store.renderStoreError e]
    BuildRegisterError e ->
      mconcat ["Build registration error via store backend: ", Store.renderRegisterError e]
    BuildConfigError e ->
      mconcat ["Build project configuration error: ", Project.renderConfigError e]
    BuildServiceError e ->
      mconcat ["Build service error: ", Service.renderServiceError e]

byId :: Store -> BuildId -> EitherT Store.FetchError IO (Maybe BuildData)
byId store build = do
  result <- Store.fetch store build
  for result $ \r ->
    case buildDataResult r of
      Nothing ->
        case buildDataHeartbeatTime r of
          Nothing -> do
            case buildDataCancelled r of
              Nothing ->
                pure r
              Just BuildNotCancelled ->
                pure r
              Just BuildCancelled ->
                pure $ r { buildDataResult = Just . fromMaybe BuildKo . buildDataResult $ r }
          Just h -> do
            now <- liftIO Time.getCurrentTime
            if Time.diffUTCTime now h > 120
              then do
                firstT Store.FetchBackendError $
                  Store.cancelx store build
                pure $ r { buildDataResult = Just . fromMaybe BuildKo . buildDataResult $ r }
              else
                pure r
      Just _ ->
        pure r

list :: Store -> Project -> Build -> EitherT Store.StoreError IO BuildTree
list store project build = do
  refs <- Store.getBuildRefs store project build
  BuildTree project build <$> (for refs $ \ref ->
    BuildTreeRef ref <$> Store.getBuildIds store project build ref)

queued :: Store -> Project -> Build -> EitherT Store.StoreError IO [BuildId]
queued store project build =
  Store.getQueued store project build

submit :: Store -> BuildService -> ProjectMode -> Project -> Build -> Maybe Ref -> EitherT BuildError IO (Maybe BuildId)
submit store buildx projectx project build ref = do
  repository' <- firstT BuildConfigError $
    Project.pick projectx project
  case repository' of
    Nothing ->
      pure Nothing
    Just repository -> do
      i <- firstT BuildStoreError $
        Store.tick store
      firstT BuildRegisterError $
        Store.register store project build i
      let
        normalised = with ref $ \rr ->
          if Text.isPrefixOf "refs/" . renderRef $ rr then rr else Ref . ((<>) "refs/heads/") . renderRef $ rr
        req = RequestBuild' $ RequestBuild i project repository build normalised
      firstT BuildServiceError $
        Service.put buildx req
      pure $ Just i

heartbeat :: Store -> BuildId -> EitherT Store.StoreError IO BuildCancelled
heartbeat store buildId =
  Store.heartbeat store buildId

acknowledge :: Store -> BuildId -> EitherT Store.StoreError IO Acknowledge
acknowledge store buildId =
  Store.acknowledge store buildId

cancel :: Store -> BuildId -> EitherT Store.FetchError IO (Maybe ())
cancel store i = do
  d <- Store.fetch store i
  for d $ \dd ->
    firstT Store.FetchBackendError $ do
      Store.cancel store (buildDataProject dd) (buildDataBuild dd) i

byCommit :: Store -> Project -> Commit -> EitherT Store.StoreError IO [BuildId]
byCommit store project commit =
  Store.getProjectCommitBuildIds store project commit

byProject :: Store -> Project -> EitherT Store.StoreError IO [Build]
byProject store project =
  Store.getProjects store project

logOf :: Store -> LogService -> BuildId -> EitherT Store.FetchError IO (Maybe (Source IO ByteString))
logOf store logs i = do
  d <- Store.fetch store i
  case d >>= buildDataLog of
    Nothing ->
      pure Nothing
    Just ld -> do
      case logs of
        CloudWatchLogs env ->
          pure . Just $ source env ld =$= Conduit.map (\t ->
            Text.encodeUtf8 $ t <> "\n")
        DevNull ->
          pure Nothing

avow :: Store -> BuildId -> Project -> Build -> Ref -> Commit -> EitherT Store.StoreError IO ()
avow store i project build ref commit = do
  Store.index store i project build ref commit

disavow :: Store -> BuildId -> Project -> Build -> EitherT Store.StoreError IO ()
disavow store i project build = do
  Store.deindex store i project build

complete :: Store -> BuildId -> BuildResult -> EitherT Store.StoreError IO ()
complete store i result = do
  Store.complete store i result

source :: Env -> LogData -> Source IO Text
source env (LogData gname sname) =
  Jebediah.source env gname sname Everything NoFollow
    =$= Jebediah.unclean
    =$= Conduit.map logChunk