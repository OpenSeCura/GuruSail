{-
 - Copyright 2026 Google LLC
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -     https://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}

-- Prints the Sail model of the extracted compiledMod; the counterpart of Guru's
-- PrettyPrinter/Rtl.hs in simulation mode (the valid flag is not checked).

module Sail where

import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Compile (compiledMod)
import ModPrinter (findDuplicateElems)
import Rtl (findInvalidNames)
import SailPrinter (ppSailTop)

main :: IO ()
main = do
  let cm@(((_, tree), _), _) = compiledMod
      dups = findDuplicateElems tree
      invalids = findInvalidNames cm
  if not (null dups && null invalids)
    then do
      mapM_ (\d -> hPutStrLn stderr ("ERROR! Duplicate element name: " ++ d)) dups
      mapM_ (\s -> hPutStrLn stderr ("ERROR! Invalid name: " ++ s)) invalids
      exitFailure
    else putStr (ppSailTop cm)
