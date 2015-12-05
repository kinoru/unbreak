-- |
-- Module       : Unbreak.Run
-- License      : AGPL-3
-- Maintainer   : Kinoru
-- Stability    : Provisional
-- Portability  : POSIX
--
-- Functions that perform the action of the Unbreak utility.
module Unbreak.Run
    ( runInit
    , runOpen
    ) where

import Prelude hiding ((++))
import Control.Exception
import System.IO
import System.IO.Error
import System.Exit

import System.Posix.ByteString
import System.Process

import Data.ByteString (ByteString)
import qualified Data.ByteString.OverheadFree as B
import qualified Data.Text.Encoding as T

import Unbreak.Crypto
import Unbreak.Format

(++) :: Monoid m => m -> m -> m
(++) = mappend

sessionPath :: ByteString
sessionPath = "/tmp/unbreak.session"

getHomePath :: IO ByteString
getHomePath = getEnv "HOME" >>= \ m -> case m of
    Nothing -> error "$HOME not found"
    Just h -> return h

-- | Creates the @~\/.unbreak.json@ file with the default configuration
-- if it's missing.
runInit :: IO ()
runInit = do
    confPath <- (++ "/.unbreak.json") <$> getHomePath
    existence <- fileExist confPath
    if existence
    then B.putStrLn "There is already the ~/.unbreak.json file.\
        \ If you are willing to create the default config file,\
        \ please delete ~/.unbreak.json and retry.\n\
        \Warning: the \"name\" part of the config may be required to open\
        \ the documents you have created in the past."
    else do
        B.writeFile confPath (enc initConf)
        B.putStrLn $ "Created the initial default configuration at " ++
            confPath

-- idempotent session
session :: Conf -> IO (ByteString, ByteString)
session Conf{..} = catchIOError
    -- get existing session
    ( do
        shelfPath <- B.readFile sessionPath
        master <- B.readFile (shelfPath ++ "/master")
        return (shelfPath, master)
    )
    -- or if that fails, create a new session
    $ const $ do
        shelfPath <- mkdtemp "/dev/shm/unbreak-"
        B.writeFile sessionPath shelfPath
        B.putStr "Type password: "
        password <- withNoEcho B.getLine <* B.putStrLn ""
        let master = scrypt password (T.encodeUtf8 name)
        B.writeFile (shelfPath ++ "/master") master
        createDirectory (shelfPath ++ "/file") 0o700
        return (shelfPath, master)

-- | Given a filename, try copying the file from the remote to a temporary
-- shared memory space, open it with the text editor specified in the config
-- file, and copy it back to the remote. Shell command @scp@ must exist.
runOpen :: ByteString -> IO ()
runOpen filename = getConf f (`editRemoteFile` filename)
  where
    f errmsg = B.putStrLn ("Failed: " ++ errmsg) *> exitFailure

getConf :: (ByteString -> IO a) -> (Conf -> IO a) -> IO a
getConf failure success = do
    confPath <- (++ "/.unbreak.json") <$> getHomePath
    existence <- fileExist confPath
    if existence
    then do
        rawConf <- B.readFile confPath
        case dec rawConf of
            Left errmsg -> failure $ B.pack errmsg
            Right conf -> success conf
    else do
        B.putStrLn "You may need to run unbreak (without arguments) first."
        failure "~/.unbreak.json does not exist"

editRemoteFile :: Conf -> ByteString -> IO ()
editRemoteFile conf@Conf{..} filename = do
    (shelfPath, master) <- session conf
    let
        filePath = mconcat [shelfPath, "/file/", filename]
        rawFilePath = filePath ++ "-enc"
        remoteFilePath = mconcat [T.encodeUtf8 remote, filename]
    -- copy the remote file to the shelf
    tryRun (mconcat ["scp ", remoteFilePath, " ", rawFilePath])
        -- if there is a file, decrypt it
        ( decrypt master <$> B.tail <$> B.readFile rawFilePath >>=
            \ m -> case m of
            CryptoPassed plaintext -> B.writeFile filePath plaintext
            CryptoFailed e -> do
                B.putStrLn $ "Decryption failed. " ++ B.pack (show e)
                exitFailure
        )
        -- or open a new file
        $ \ n -> B.putStrLn $ mconcat
            ["Download failed. (", B.pack $ show n, ")\nOpening a new file."]
    -- edit the file in the shelf
    run (mconcat [T.encodeUtf8 editor, " ", filePath]) $ const $ do
        B.putStrLn "Editor exited abnormally. Editing cancelled."
        exitFailure
    -- encrypt the file
    edited <- B.readFile filePath
    nonce <- getRandomBytes 12
    B.writeFile rawFilePath $
        -- adding the version number, for forward compatibility
        "\0" ++ (throwCryptoError $ encrypt nonce master edited)
    -- upload the file from the shelf to the remote
    run (mconcat ["scp ", rawFilePath, " ", remoteFilePath]) $
        \ n -> B.putStrLn $ mconcat
            ["Upload failed. (", B.pack $ show n, ")"]
    B.putStrLn "Done."

withNoEcho :: IO a -> IO a
withNoEcho action = do
    old <- hGetEcho stdin
    bracket_ (hSetEcho stdin False) (hSetEcho stdin old) action

run :: ByteString -> (Int -> IO ()) -> IO ()
run cmd = tryRun cmd (return ())

tryRun :: ByteString -> IO a -> (Int -> IO a) -> IO a
tryRun cmd successHandler failHandler = do
    -- TODO: avoid the String <-> ByteString overhead
    (_, _, _, p) <- createProcess (shell $ B.unpack cmd)
    c <- waitForProcess p
    case c of
        ExitFailure n -> failHandler n
        _ -> successHandler