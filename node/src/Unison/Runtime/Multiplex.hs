{-# Language BangPatterns #-}
{-# Language DeriveGeneric #-}
{-# Language GeneralizedNewtypeDeriving #-}
{-# Language TupleSections #-}

module Unison.Runtime.Multiplex where

import System.IO (Handle, stdin, stdout, hFlush, hSetBinaryMode)
import Control.Applicative
import Control.Concurrent.Async (Async)
import Control.Concurrent.MVar
import Control.Concurrent.STM as STM
import Control.Exception (catch,throwIO,SomeException,mask_)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Reader (ReaderT,runReaderT,MonadReader)
import Data.Bytes.Serial (Serial(serialize,deserialize))
import Data.Functor
import Data.IORef
import Data.Maybe
import Data.Word
import GHC.Generics
import qualified Control.Concurrent as C
import qualified Control.Concurrent.Async as Async
import qualified Control.Monad.Reader as Reader
import qualified Crypto.Random as Random
import qualified Data.ByteString as B
import qualified Data.Bytes.Get as Get
import qualified Data.Bytes.Put as Put
import qualified Data.Serialize.Get as Get
import qualified STMContainers.Map as M
import qualified Unison.Cryptography as C
import qualified Unison.Runtime.Queue as Q
-- import Control.Concurrent.STM

data Packet = Packet { destination :: !B.ByteString, content :: !B.ByteString } deriving (Generic,Show)
instance Serial Packet

type IsSubscription = Bool

data Callbacks =
  Callbacks (M.Map B.ByteString (B.ByteString -> IO ())) (TVar Word64)

type Env = (STM Packet -> STM (), Callbacks, IO B.ByteString, String -> IO ())

newtype Multiplex a = Multiplex (ReaderT Env IO a)
  deriving (Applicative, Alternative, Functor, Monad, MonadIO, MonadPlus, MonadReader Env)

run :: Env -> Multiplex a -> IO a
run env (Multiplex go) = runReaderT go env

liftLogged :: String -> IO a -> Multiplex a
liftLogged msg action = ask >>= \env -> liftIO $ catch action (handle env) where
  handle :: Env -> SomeException -> IO a
  handle env ex = run env (info $ msg ++ " " ++ show ex) >> throwIO ex

-- | Run the multiplexed computation using stdin and stdout, terminating
-- after a period of inactivity exceeding sleepAfter. `rem` is prepended
-- onto stdin.
runStandardIO :: (String -> IO ()) -> Microseconds -> B.ByteString -> IO ()
              -> Multiplex a -> IO a
runStandardIO info sleepAfter rem interrupt m = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  fresh <- uniqueChannel
  output <- atomically Q.empty :: IO (Q.Queue (Maybe Packet))
  input <- atomically newTQueue :: IO (TQueue (Maybe Packet))
  cb0@(Callbacks cbm cba) <- Callbacks <$> atomically M.new <*> atomically (newTVar 0)
  let env = (Q.enqueue output . (Just <$>), cb0, fresh, info)
  activity <- atomically $ newTVar 0
  let bump = atomically $ modifyTVar' activity (1+)
  _ <- Async.async $ do interrupt; atomically $ writeTQueue input Nothing
  reader <- Async.async $ do
    let write pk n = bump >> info ("[Mux.runStandardIO] read " ++ show n ++ " bytes")
                          >> info ("[Mux.runStandardIO] sending to " ++ show (destination pk))
                          >> atomically (writeTQueue input (Just pk))
    deserializeHandle stdin rem write
    bump
    atomically $ writeTQueue input Nothing
  writer <- Async.async . repeatWhile $ do
    packet <- atomically $ Q.tryDequeue output :: IO (Maybe (Maybe Packet))
    packet <- case packet of
      -- writer is saturated, don't bother flushing output buffer
      Just packet -> pure packet
      -- writer not saturated; flush output buffer to avoid latency and/or deadlock
      Nothing -> hFlush stdout >> atomically (Q.dequeue output)
    B.putStr (Put.runPutS (serialize packet))
    case packet of
      Nothing -> False <$ info "[Mux.runStandardIO] shutting down output thread"
      Just packet -> do
        info $ "[Mux.runStandardIO] sent packet@" ++ show (destination packet)
        True <$ bump
  watchdog <- Async.async . repeatWhile $ do
    activity0 <- (+) <$> readTVarIO activity <*> readTVarIO cba
    C.threadDelay sleepAfter
    activity1 <- (+) <$> readTVarIO activity <*> readTVarIO cba
    nothingPending <- atomically $ M.null cbm
    atomically $
      if activity0 == activity1 && nothingPending then do
        writeTQueue input Nothing
        Q.enqueue output (pure Nothing)
        pure False
      else
        pure True
  a <- run env m
  processor <- Async.async $ run env (process $ atomically (readTQueue input))
  Async.wait watchdog
  Async.wait reader
  Async.wait processor
  Async.wait writer
  pure a

deserializeHandle :: Serial a => Handle -> B.ByteString -> (a -> Int -> IO ()) -> IO ()
deserializeHandle h rem write = go (Get.runGetPartial deserialize rem) where
  go dec = do
    (a, n, rem') <- deserializeHandle1 h dec
    write a (n + B.length rem)
    go (Get.runGetPartial deserialize rem')

deserializeHandle1' :: Serial a => Handle -> IO (a, Int, B.ByteString)
deserializeHandle1' h = deserializeHandle1 h (Get.runGetPartial deserialize B.empty)

deserializeHandle1 :: Handle -> Get.Result a -> IO (a, Int, B.ByteString)
deserializeHandle1 h dec = go dec 0 where
  go result !n = case result of
    Get.Fail msg _ -> fail msg
    Get.Partial k -> do
      bs <- B.hGetSome h 65536
      go (k bs) (n + B.length bs)
    Get.Done a rem -> pure (a, n, rem)

ask :: Multiplex Env
ask = Multiplex Reader.ask

bumpActivity :: Multiplex ()
bumpActivity = do
  (_, Callbacks _ cba, _, _) <- ask
  liftIO $ bumpActivity' cba

bumpActivity' :: TVar Word64 -> IO ()
bumpActivity' cba = atomically $ modifyTVar' cba (1+)

process1 :: Packet -> Multiplex ()
process1 (Packet destination content) = do
  (_, Callbacks cbs cba, _, info) <- ask
  callback <- liftIO . atomically $ M.lookup destination cbs
  liftIO $ case callback of
    Nothing -> info $ "Dropped packet for destination: " ++ show destination
    Just callback -> bumpActivity' cba >> callback content

info :: String -> Multiplex ()
info msg = do
  (_, _, _, log) <- ask
  liftIO $ log msg

process :: IO (Maybe Packet) -> Multiplex ()
process recv = do
  (_, Callbacks cbs cba, _, info) <- ask
  liftIO . repeatWhile $ do
    packet <- recv
    case packet of
      Nothing -> info "[Mux.process] EOF" >> pure False
      Just (Packet destination content) -> do
        info $ "[Mux.process] packet sent to " ++ show destination
        callback <- atomically $ M.lookup destination cbs
        case callback of
          Nothing -> do
            info $ "[Mux.process] Dropped packet for destination: " ++ show destination
            pure True
          Just callback -> do
            bumpActivity' cba
            callback content
            pure True

repeatWhile :: Monad f => f Bool -> f ()
repeatWhile action = do
  ok <- action
  when ok (repeatWhile action)

untilDefined :: Monad f => f (Maybe a) -> f a
untilDefined action = do
  ok <- action
  case ok of
    Nothing -> untilDefined action
    Just a -> pure a

uniqueChannel :: IO (IO B.ByteString)
uniqueChannel = do
  nonce <- newIORef (0 :: Word)
  rng <- newIORef =<< Random.getSystemDRG
  pure $ do
    n <- atomicModifyIORef' nonce (\n -> (n+1,n))
    (bytes,rng') <- Random.randomBytesGenerate 12 <$> readIORef rng
    _ <- atomicModifyIORef' rng (\_ -> (rng',rng'))
    pure . Put.runPutS $ Put.putByteString (Put.runPutS $ serialize n) >> Put.putByteString bytes

callbacks0 :: STM Callbacks
callbacks0 = Callbacks <$> M.new <*> newTVar 0

data Channel a = Channel (Type a) B.ByteString deriving Generic

newtype EncryptedChannel u o i = EncryptedChannel (Channel B.ByteString) deriving Generic
instance Serial (EncryptedChannel u o i)

erase :: EncryptedChannel u o i -> Channel B.ByteString
erase (EncryptedChannel chan) = chan

channelId :: Channel a -> B.ByteString
channelId (Channel _ id) = id

instance Serial (Channel a)

data Type a = Type deriving Generic
instance Serial (Type a)

type Request a b = Channel (a, Channel b)

type Microseconds = Int

requestTimedVia' :: (Serial a, Serial b)
                 => Microseconds
                 -> (STM (a, Channel b) -> Multiplex ())
                 -> Channel b
                 -> STM a
                 -> Multiplex (Multiplex b)
requestTimedVia' micros send replyTo a = do
  env <- ask
  (receive, cancel) <- receiveCancellable replyTo
  send $ (,replyTo) <$> a
  watchdog <- liftIO . C.forkIO $ do
    liftIO $ C.threadDelay micros
    run env cancel
  pure $ receive <* liftIO (C.killThread watchdog)

requestTimedVia :: (Serial a, Serial b) => Microseconds -> Request a b -> Channel b -> STM a
                -> Multiplex (Multiplex b)
requestTimedVia micros req replyTo a =
  requestTimedVia' micros (send' req) replyTo a

requestTimed' :: (Serial a, Serial b) => Microseconds -> Request a b -> STM a -> Multiplex (Multiplex b)
requestTimed' micros req a = do
  replyTo <- channel
  requestTimedVia micros req replyTo a

requestTimed :: (Serial a, Serial b) => Microseconds -> Request a b -> a -> Multiplex (Multiplex b)
requestTimed micros req a = do
  replyTo <- channel
  env <- ask
  (receive, cancel) <- receiveCancellable replyTo
  send req (a, replyTo)
  watchdog <- liftIO . C.forkIO $ do
    liftIO $ C.threadDelay micros
    run env cancel
  pure $ receive <* liftIO (C.killThread watchdog)

type Cleartext = B.ByteString
type Ciphertext = B.ByteString
type CipherState = (Cleartext -> STM Ciphertext, Ciphertext -> STM Cleartext)

encryptedRequestTimedVia
  :: (Serial a, Serial b)
  => CipherState
  -> Microseconds
  -> ((a,Channel b) -> Multiplex ())
  -> Channel b
  -> a
  -> Multiplex b
encryptedRequestTimedVia (_,decrypt) micros send replyTo@(Channel _ bs) a = do
  responseCiphertext <- receiveTimed micros (Channel Type bs)
  send (a, replyTo)
  responseCiphertext <- responseCiphertext -- force the receive
  responseCleartext <- liftIO . atomically . decrypt $ responseCiphertext
  either fail pure $ Get.runGetS deserialize responseCleartext

encryptAndSendTo
  :: (Serial a, Serial node)
  => node -> Channel B.ByteString -> (Cleartext -> STM Ciphertext) -> a
  -> Multiplex ()
encryptAndSendTo recipient chan encrypt a = do
  let bytes = Put.runPutS (serialize a)
  bytes `seq` nest recipient (send' chan (encrypt bytes))

encryptAndSendTo'
  :: (Serial a, Serial node)
  => node -> Channel a -> (Cleartext -> STM Ciphertext) -> a
  -> Multiplex ()
encryptAndSendTo' recipient (Channel _ chan) encrypt a =
  encryptAndSendTo' recipient (Channel Type chan) encrypt a

fork :: Multiplex a -> Multiplex (Async a)
fork m = do
  env <- ask
  liftIO . Async.async $ run env m

nest :: Serial k => k -> Multiplex a -> Multiplex a
nest outer m = Reader.local tweak m where
  tweak (send,cbs,fresh,log) = (send' send,cbs,fresh,log)
  kbytes = Put.runPutS (serialize outer)
  send' send p = send $ (\p -> Packet kbytes (Put.runPutS (serialize p))) <$> p

channel :: Multiplex (Channel a)
channel = do
  ~(_,_,fresh,_) <- ask
  Channel Type <$> liftIO fresh

send :: Serial a => Channel a -> a -> Multiplex ()
send chan a = send' chan (pure a)

send' :: Serial a => Channel a -> STM a -> Multiplex ()
send' (Channel _ key) a = do
  ~(send,_,_,_) <- ask
  liftIO . atomically $ send (Packet key . Put.runPutS . serialize <$> a)

receiveCancellable :: Serial a => Channel a -> Multiplex (Multiplex a, Multiplex ())
receiveCancellable (Channel _ key) = do
  (_,Callbacks cbs cba,_,_) <- ask
  result <- liftIO newEmptyMVar
  liftIO . atomically $ M.insert (putMVar result . Right) key cbs
  liftIO $ bumpActivity' cba
  cancel <- pure $ do
    liftIO . atomically $ M.delete key cbs
    liftIO $ putMVar result (Left "cancelled")
  force <- pure . liftIO $ do
    bytes <- takeMVar result
    bytes <- either fail pure bytes
    either fail pure $ Get.runGetS deserialize bytes
  pure (force, cancel)

receiveTimed :: Serial a => Microseconds -> Channel a -> Multiplex (Multiplex a)
receiveTimed micros chan = do
  (force, cancel) <- receiveCancellable chan
  env <- ask
  watchdog <- liftIO . C.forkIO $ do
    liftIO $ C.threadDelay micros
    run env cancel
  pure $ force <* liftIO (C.killThread watchdog)

timeout' :: Microseconds -> a -> Multiplex a -> Multiplex a
timeout' micros onTimeout m = fromMaybe onTimeout <$> timeout micros m

timeout :: Microseconds -> Multiplex a -> Multiplex (Maybe a)
timeout micros m = do
  env <- ask
  t1 <- liftIO $ Async.async (Just <$> run env m)
  t2 <- liftIO $ Async.async (C.threadDelay micros $> Nothing)
  liftIO $ snd <$> Async.waitAnyCancel [t1, t2]

subscribeTimed :: Serial a => Microseconds -> Channel a -> Multiplex (Multiplex (Maybe a), Multiplex ())
subscribeTimed micros chan = do
  (fetch, cancel) <- subscribe chan
  env <- ask
  activity <- liftIO . atomically . newTVar $ False
  alive <- liftIO . atomically . newTVar $ True
  fetch' <- pure $ do
    liftIO . atomically $ writeTVar activity True
    ok <- liftIO $ readTVarIO alive
    case ok of
      True -> Just <$> fetch
      False -> pure Nothing
  let cleanup = cancel >> (liftIO . atomically . writeTVar alive $ False)
  watchdog <- liftIO . C.forkIO . run env $ loop activity cleanup
  cancel' <- pure $ cleanup >> liftIO (C.killThread watchdog)
  pure (fetch', cancel')
  where
  loop activity cleanup = do
    liftIO . atomically $ writeTVar activity False
    liftIO $ C.threadDelay micros
    active <- liftIO . atomically $ readTVar activity
    case active of
      False -> cleanup -- no new fetches in last micros period
      True -> loop activity cleanup

subscribe :: Serial a => Channel a -> Multiplex (Multiplex a, Multiplex ())
subscribe (Channel _ key) = do
  (_, Callbacks cbs cba, _, _) <- ask
  q <- liftIO . atomically $ newTQueue
  liftIO . atomically $ M.insert (atomically . writeTQueue q) key cbs
  liftIO $ bumpActivity' cba
  unsubscribe <- pure . liftIO . atomically . M.delete key $ cbs
  force <- pure . liftIO $ do
    bytes <- atomically $ readTQueue q
    either fail pure $ Get.runGetS deserialize bytes
  pure (force, unsubscribe)

seconds :: Microseconds -> Int
seconds micros = micros * 1000000

attemptMasked :: IO a -> IO (Either String a)
attemptMasked a =
  catch (Right <$> mask_ a) (\e -> pure (Left $ show (e :: SomeException)))

handshakeTimeout :: Microseconds
handshakeTimeout = seconds 5

connectionTimeout :: Microseconds
connectionTimeout = seconds 45

delayBeforeFailure :: Microseconds
delayBeforeFailure = seconds 2

pipeInitiate
  :: (Serial i, Serial o, Serial key, Serial u, Serial node)
  => C.Cryptography key t1 t2 t3 t4 t5 Cleartext
  -> EncryptedChannel u o i
  -> (node,key)
  -> u
  -> Multiplex (Maybe o -> Multiplex (), Multiplex (Maybe i), CipherState)
pipeInitiate crypto rootChan (recipient,recipientKey) u = do
  info "[Mux.pipeInitiate] starting"
  (doneHandshake, encrypt, decrypt) <- liftIO $ C.pipeInitiator crypto recipientKey
  handshakeChan <- channel
  connectedChan <- channel
  handshakeSub <- subscribeTimed handshakeTimeout handshakeChan
  connectedSub <- subscribeTimed connectionTimeout connectedChan
  handshake doneHandshake encrypt decrypt (handshakeChan,connectedChan) handshakeSub connectedSub
  where
  handshake doneHandshake encrypt decrypt cs@(chanh,chanc) (fetchh,cancelh) (fetchc,cancelc) =
    encryptAndSendTo recipient (erase rootChan) encrypt (u,cs) >> go
    where
    recv = untilDefined $ do
      bytes <- fetchc
      case bytes of
        Nothing -> pure (Just Nothing)
        Just bytes -> do
          decrypted <- liftIO . atomically $ decrypt bytes
          case Get.runGetS deserialize decrypted of
            Left err -> info err >> pure Nothing
            Right mi -> pure (Just mi)
    go = do
      ready <- liftIO $ atomically doneHandshake
      info $ "[Mux.pipeInitiate] ready: " ++ show ready
      case ready of
        True -> do
          info "[Mux.pipeInitiate] handshake complete"
          encryptAndSendTo recipient chanh encrypt () -- todo: not sure this flush needed
          pure (encryptAndSendTo recipient chanc encrypt, recv, (encrypt,decrypt))
        False -> do
          info "[Mux.pipeInitiate] handshake round trip... "
          nest recipient $ send' chanh (encrypt B.empty)
          bytes <- fetchh
          info "[Mux.pipeInitiate] ... handshake round trip completed"
          case bytes of
            Nothing -> cancelh >> cancelc >> fail "cancelled handshake"
            Just bytes -> liftIO (atomically $ decrypt bytes) >> go

-- todo: add access control here, better to bail ASAP (or after 1s delay
-- to discourage sniffing for nodes with access) rather than continuing with
-- handshake if we know we can't accept messages from that party
pipeRespond
  :: (Serial o, Serial i, Serial u, Serial node)
  => C.Cryptography key t1 t2 t3 t4 t5 Cleartext
  -> (key -> Multiplex Bool)
  -> EncryptedChannel u i o
  -> (u -> node)
  -> B.ByteString
  -> Multiplex (key, u, Maybe o -> Multiplex (), Multiplex (Maybe i), CipherState)
pipeRespond crypto allow _ extractSender payload = do
  (doneHandshake, senderKey, encrypt, decrypt) <- liftIO $ C.pipeResponder crypto
  bytes <- (liftIO . atomically . decrypt) payload
  (u, chans@(handshakeChan,connectedChan)) <- either fail pure $ Get.runGetS deserialize bytes
  let sender = extractSender u
  handshakeSub <- subscribeTimed handshakeTimeout handshakeChan
  connectedSub <- subscribeTimed connectionTimeout connectedChan
  handshake doneHandshake senderKey encrypt decrypt chans handshakeSub connectedSub sender u
  where
  handshake doneHandshake senderKey encrypt decrypt (chanh,chanc) (fetchh,cancelh) (fetchc,cancelc) sender u = go
    where
    recv = untilDefined $ do
      bytes <- fetchc
      case bytes of
        Nothing -> pure (Just Nothing)
        Just bytes -> do
          decrypted <- liftIO . atomically $ decrypt bytes
          case Get.runGetS deserialize decrypted of
            Left err -> info err >> pure Nothing
            Right mi -> pure (Just mi)
    checkSenderKey = do
      senderKey <- liftIO $ atomically senderKey
      case senderKey of
        Nothing -> pure ()
        Just senderKey -> allow senderKey >>= \ok ->
          if ok then pure ()
          else liftIO (C.threadDelay delayBeforeFailure) >> fail "disallowed key"
    go = do
      ready <- liftIO $ atomically doneHandshake
      checkSenderKey
      case ready of
        True -> do
          encryptAndSendTo sender chanh encrypt () -- todo: not sure this flush needed
          Just senderKey <- liftIO $ atomically senderKey
          pure (senderKey, u, encryptAndSendTo sender chanc encrypt, recv, (encrypt,decrypt))
        False -> do
          nest sender $ send' chanh (encrypt B.empty)
          bytes <- fetchh
          case bytes of
            Nothing -> cancelh >> cancelc >> fail "cancelled handshake"
            Just bytes -> liftIO (atomically $ decrypt bytes) >> go
