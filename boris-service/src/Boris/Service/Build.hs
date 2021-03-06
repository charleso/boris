{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Boris.Service.Build (
    BuilderError (..)
  , builder
  , renderBuilderError
  ) where

import           Boris.Build
import           Boris.Core.Data
import           Boris.Service.Boot
import           Boris.Service.Git
import           Boris.Service.Log
import qualified Boris.Service.Remote as Remote
import           Boris.Service.Workspace

import           Control.Concurrent.Async (async, waitEitherCancel)
import           Control.Monad.IO.Class (MonadIO (..))

import           P

import           System.IO (IO)

import           Tine.Conduit (WithEnv (..))
import qualified Tine.Conduit as X

import           Twine.Snooze (seconds, snooze)

import           X.Control.Monad.Trans.Either (EitherT, joinEitherE, newEitherT, runEitherT)

data BuilderError =
    BuildLogError LogError
  | BuildRemoteError Remote.RemoteError

data LifecycleError =
    LifecycleInitialiseError InitialiseError
  | LifecycleRemoteError Remote.RemoteError

-- |
-- Basic executor flow:
--
--  * pick a build off the queue.
--
--  * we try to acknowledge it, dropping it if someone else has already
--    picked up the build.
--
--  * we create a new workspace based on the build-id.
--
--  * we initialise the workspace:
--     * get the repository
--     * read the configs
--     * determine the specifics of this build
--     * see 'Boris.Service.Git' for all the details.
--
--  * we run the actual build:
--     * See 'Boris.Build' for all the details.
--
--  * we record the results.
--
--
builder :: LogService -> BuildService -> WorkspacePath -> BuildId -> Project -> Repository -> Build -> Maybe Ref -> EitherT BuilderError IO ()
builder logs builds w buildId project repository build mref = do
  joinEitherE join . newEitherT . firstT BuildLogError . withLogger logs $ \out -> runEitherT $ do
    initial <- firstT BuildRemoteError $
      Remote.heartbeat builds buildId

    ack <- firstT BuildRemoteError $
      Remote.acknowledge builds buildId

    case (ack, initial) of
      (Accept, BuildNotCancelled) -> do
        let
          heartbeater =
            runEitherT $ do
              heart <- firstT BuildRemoteError $
                Remote.heartbeat builds buildId
              case heart of
                BuildCancelled ->
                  pure ()
                BuildNotCancelled -> do
                  liftIO . snooze . seconds $ 30
                  newEitherT heartbeater

        heartbeater' <- liftIO . async $ heartbeater
        lifecycle' <- liftIO . async . runEitherT $ lifecycle out builds w project build repository mref buildId

        state <- liftIO $ waitEitherCancel heartbeater' lifecycle'

        result <- case state of
          -- we couldn't send a heartbeat, so had to give up, this should be rare, but can happen.
          Left (Left err) -> do
            X.xPutStrLn out $ mconcat ["| boris:ko:heartbeat-error | ", renderBuilderError err]
            pure $ BuildKo

          -- we were cancelled, nothing more to see here.
          Left (Right _) -> do
            X.xPutStrLn out $ mconcat ["| boris:ko:cancelled | "]
            pure $ BuildKo

          -- initialisation error, wasn't even a valid build we ditch it all together
          Right (Left err) -> do
            X.xPutStrLn out $ mconcat ["| boris:ko:initialization | ", renderLifecycleError err]
            pure $ BuildKo

          -- build completed but failed.
          Right (Right (Left err)) -> do
            X.xPutStrLn out $ mconcat ["| boris:ko | ", renderBuildError err]
            pure $ BuildKo

          -- build completed, defied all odds, and actually succeeded.
          Right (Right (Right ())) -> do
            X.xPutStrLn out $ "| boris:ok |"
            pure $ BuildOk

        firstT BuildRemoteError $
          Remote.complete builds buildId result

      (AlreadyRunning, BuildCancelled) ->
        pure ()

      (AlreadyRunning, BuildNotCancelled) ->
        pure ()

      (Accept, BuildCancelled) ->
        firstT BuildRemoteError $
          Remote.complete builds buildId BuildKo


lifecycle :: X.Out -> BuildService -> WorkspacePath -> Project -> Build -> Repository -> Maybe Ref -> BuildId -> EitherT LifecycleError IO (Either BuildError ())
lifecycle out builds w project build repository mref buildId =
  withWorkspace w buildId $ \workspace -> do
    instant <- firstT LifecycleInitialiseError $
      initialise out out workspace build repository mref

    let
      ref = buildRef instant
      commit = buildCommit instant
      specification = buildSpecification instant

      -- FIX inherit list should be defined externally
      context = [
          InheritEnv "AWS_DEFAULT_REGION"
        , InheritEnv "AMBIATA_ARTEFACTS_MASTER"
        , InheritEnv "AMBIATA_HADDOCK"
        , InheritEnv "AMBIATA_DOWNLOAD"
        , InheritEnv "AMBIATA_MAFIA_CACHE"
        , InheritEnv "AMBIATA_ARTEFACTS_BRANCHES"
        , InheritEnv "AMBIATA_BENCHMARK_RESULTS"
        , InheritEnv "AMBIATA_TEST_BUCKET"
        , InheritEnv "AMBIATA_IVY_PAY"
        , InheritEnv "AMBIATA_IVY_OSS"
        , InheritEnv "AMBIATA_DOC"
        , InheritEnv "AMBIATA_DISPENSARY"
        , InheritEnv "HOME"
        , InheritEnv "TMPDIR"
        , InheritEnv "PATH"
        , InheritEnv "LOCALE"
        , InheritEnv "LC_COLLATE"
        , InheritEnv "LANG"
        , InheritEnv "HOSTNAME"
        , InheritEnv "SHELL"
        , InheritEnv "TERM"
        , InheritEnv "USER"
        , InheritEnv "RBENV_ROOT"
        , InheritEnv "HADOOP_USER_NAME"
        , InheritEnv "HADOOP_CONF_BASE"
        , SetEnv "BORIS_BUILD_ID" (renderBuildId buildId)
        , SetEnv "BORIS_PROJECT" (renderProject project)
        , SetEnv "BORIS_BUILD" (renderBuild build)
        , SetEnv "BORIS_REF" (renderRef ref)
        , SetEnv "BORIS_COMMIT" (renderCommit commit)
        ]

    firstT LifecycleRemoteError $
      Remote.avow builds buildId ref commit

    liftIO . runEitherT $
      runBuild out out workspace specification context

renderBuilderError :: BuilderError -> Text
renderBuilderError err =
  case err of
    BuildLogError e ->
      mconcat ["Error commissioning log: ", renderLogError e]
    BuildRemoteError e ->
      mconcat ["Error contacting server: ", Remote.renderRemoteError e]

renderLifecycleError :: LifecycleError -> Text
renderLifecycleError err =
  case err of
    LifecycleInitialiseError e ->
      mconcat ["An error occurred trying to initialise git repository: ", renderInitialiseError e]
    LifecycleRemoteError e ->
      mconcat ["An error occurred trying to confirm ref with remote: ", Remote.renderRemoteError e]
