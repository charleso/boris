import qualified Test.Boris.Core.Data
import qualified Test.Boris.Core.Serial.Command
import qualified Test.Boris.Core.Serial.Ref

import           Disorder.Core.Main


main :: IO ()
main =
  disorderMain [
      Test.Boris.Core.Data.tests
    , Test.Boris.Core.Serial.Ref.tests
    , Test.Boris.Core.Serial.Command.tests
    ]
