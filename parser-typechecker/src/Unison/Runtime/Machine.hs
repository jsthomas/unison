{-# language DataKinds #-}
{-# language RankNTypes #-}
{-# language BangPatterns #-}

module Unison.Runtime.Machine where

import Data.Maybe (fromMaybe)

import Data.Bits
import Data.String (fromString)
import Data.Traversable
import Data.Word (Word64)

import qualified Data.Text as Tx
import qualified Data.Map.Strict as M

import Control.Exception
import Control.Lens ((<&>))
import Control.Concurrent (forkIOWithUnmask, ThreadId)
import Control.Exception (try, mask)
import Control.Monad ((<=<))

import qualified Data.Primitive.PrimArray as PA

import Text.Read (readMaybe)

import Unison.Runtime.ANF (Mem(..))
import Unison.Runtime.Foreign
import Unison.Runtime.Stack
import Unison.Runtime.MCode

import qualified Unison.Type as Rf
import qualified Unison.Runtime.IOSource as Rf

import Unison.Util.EnumContainers as EC
import Unison.Util.Pretty as P

type Tag = Word64
type Env = Word64 -> Comb
type DEnv = EnumMap Word64 Closure

type Unmask = forall a. IO a -> IO a

newtype RuntimeExn = RE { prettyError :: P.Pretty P.ColorText }
  deriving (Show)
instance Exception RuntimeExn

die :: String -> IO a
die = throwIO . RE . P.lit . fromString

info :: Show a => String -> a -> IO ()
info ctx x = infos ctx (show x)
infos :: String -> String -> IO ()
infos ctx s = putStrLn $ ctx ++ ": " ++ s

eval0 :: Env -> Section -> IO ()
eval0 !env !co = do
  ustk <- alloc
  bstk <- alloc
  mask $ \unmask -> eval unmask env mempty ustk bstk KE co

apply0
  :: Maybe (Stack 'UN -> Stack 'BX -> IO ())
  -> Env -> Word64 -> IO ()
apply0 !callback !env !i = do
  ustk <- alloc
  bstk <- alloc
  mask $ \unmask ->
    apply unmask env mempty ustk bstk k0 True ZArgs comb
  where
  comb = PAp (IC i $ env i) unull bnull
  k0 = maybe KE (CB . Hook) callback

lookupDenv :: Word64 -> DEnv -> Closure
lookupDenv p denv = fromMaybe BlackHole $ EC.lookup p denv

exec
  :: Unmask -> Env -> DEnv
  -> Stack 'UN -> Stack 'BX -> K
  -> Instr
  -> IO (DEnv, Stack 'UN, Stack 'BX, K)
exec _      !_   !denv !ustk !bstk !k (Info tx) = do
  info tx ustk
  info tx bstk
  info tx k
  pure (denv, ustk, bstk, k)
exec _      !env !denv !ustk !bstk !k (Name n args) = do
  bstk <- name ustk bstk args (IC n $ env n)
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (SetDyn p i) = do
  clo <- peekOff bstk i
  pure (EC.mapInsert p clo denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Capture p) = do
  (sk,denv,ustk,bstk,useg,bseg,k) <- splitCont denv ustk bstk k p
  bstk <- bump bstk
  poke bstk $ Captured sk useg bseg
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (UPrim1 op i) = do
  ustk <- uprim1 ustk op i
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (UPrim2 op i j) = do
  ustk <- uprim2 ustk op i j
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (BPrim1 op i) = do
  (ustk,bstk) <- bprim1 ustk bstk op i
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (BPrim2 op i j) = do
  (ustk,bstk) <- bprim2 ustk bstk op i j
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Pack t args) = do
  clo <- buildData ustk bstk t args
  bstk <- bump bstk
  poke bstk clo
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Unpack i) = do
  (ustk, bstk) <- dumpData ustk bstk =<< peekOff bstk i
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Print i) = do
  m <- peekOff ustk i
  print m
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Lit (MI n)) = do
  ustk <- bump ustk
  poke ustk n
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Lit (MD d)) = do
  ustk <- bump ustk
  pokeD ustk d
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Lit (MT t)) = do
  bstk <- bump bstk
  poke bstk (Foreign (Wrap Rf.textRef t))
  pure (denv, ustk, bstk, k)
exec _      !_   !denv !ustk !bstk !k (Reset ps) = do
  pure (denv, ustk, bstk, Mark ps clos k)
 where clos = EC.restrictKeys denv ps
exec unmask !_   !denv !ustk !bstk !k (ForeignCall catch (FF f) args)
    = foreignArgs ustk bstk args
  >>= perform
  <&> uncurry (denv,,,k)
  where
  perform
    | catch = foreignCatch unmask ustk bstk f
    | otherwise = foreignResult ustk bstk <=< f
exec unmask !env !denv !ustk !bstk !k (Fork lz) = do
  tid <-
    unmask $ forkEval env denv k lz <$> duplicate ustk <*> duplicate bstk
  bstk <- bump bstk
  poke bstk . Foreign . Wrap Rf.threadIdReference $ tid
  pure (denv, ustk, bstk, k)
{-# inline exec #-}

maskTag :: Word64 -> Word64
maskTag i = i .&. 0xFFFF

eval :: Unmask -> Env -> DEnv
     -> Stack 'UN -> Stack 'BX -> K -> Section -> IO ()
eval unmask !env !denv !ustk !bstk !k (Match i (TestT df cs)) = do
  t <- peekOffT bstk i
  eval unmask env denv ustk bstk k $ selectTextBranch t df cs
eval unmask !env !denv !ustk !bstk !k (Match i br) = do
  t <- peekOffN ustk i
  eval unmask env denv ustk bstk k $ selectBranch t br
eval unmask !env !denv !ustk !bstk !k (Yield args) = do
  (ustk, bstk) <- moveArgs ustk bstk args
  ustk <- frameArgs ustk
  bstk <- frameArgs bstk
  yield unmask env denv ustk bstk k
eval unmask !env !denv !ustk !bstk !k (App ck r args) =
  resolve env denv ustk bstk r
    >>= apply unmask env denv ustk bstk k ck args
eval unmask !env !denv !ustk !bstk !k (Call ck n args) =
  enter unmask  env denv ustk bstk k ck args $ env n
eval unmask !env !denv !ustk !bstk !k (Jump i args) =
  peekOff bstk i >>= jump unmask env denv ustk bstk k args
eval unmask !env !denv !ustk !bstk !k (Let nw nx) = do
  (ustk, ufsz, uasz) <- saveFrame ustk
  (bstk, bfsz, basz) <- saveFrame bstk
  eval unmask env denv ustk bstk (Push ufsz bfsz uasz basz nx k) nw
eval unmask !env !denv !ustk !bstk !k (Ins i nx) = do
  (denv, ustk, bstk, k) <- exec unmask env denv ustk bstk k i
  eval unmask env denv ustk bstk k nx
eval _      !_   !_    !_    !_    !_ Exit = pure ()
eval _      !_   !_    !_    !_    !_ (Die s) = die s
{-# noinline eval #-}

forkEval
  :: Env -> DEnv -> K -> Section -> Stack 'UN -> Stack 'BX -> IO ThreadId
forkEval env denv k nx ustk bstk = forkIOWithUnmask $ \unmask -> do
  (denv, ustk, bstk, k) <- discardCont denv ustk bstk k 0
  eval unmask env denv ustk bstk k nx
{-# inline forkEval #-}

-- fast path application
enter
  :: Unmask -> Env -> DEnv -> Stack 'UN -> Stack 'BX -> K
  -> Bool -> Args -> Comb -> IO ()
enter unmask !env !denv !ustk !bstk !k !ck !args !comb = do
  ustk <- if ck then ensure ustk uf else pure ustk
  bstk <- if ck then ensure bstk bf else pure bstk
  (ustk, bstk) <- moveArgs ustk bstk args
  ustk <- acceptArgs ustk ua
  bstk <- acceptArgs bstk ba
  eval unmask env denv ustk bstk k entry
  where
  Lam ua ba uf bf entry = comb
{-# inline enter #-}

-- fast path by-name delaying
name :: Stack 'UN -> Stack 'BX -> Args -> IComb -> IO (Stack 'BX)
name !ustk !bstk !args !comb = do
  (useg, bseg) <- closeArgs ustk bstk unull bnull args
  bstk <- bump bstk
  poke bstk $ PAp comb useg bseg
  pure bstk
{-# inline name #-}

-- slow path application
apply
  :: Unmask -> Env -> DEnv -> Stack 'UN -> Stack 'BX -> K
  -> Bool -> Args -> Closure -> IO ()
apply unmask !env !denv !ustk !bstk !k !ck !args clo = case clo of
  PAp comb@(Lam_ ua ba uf bf entry) useg bseg
    | ck || ua <= uac && ba <= bac -> do
      ustk <- ensure ustk uf
      bstk <- ensure bstk bf
      (ustk, bstk) <- moveArgs ustk bstk args
      ustk <- dumpSeg ustk useg A
      bstk <- dumpSeg bstk bseg A
      ustk <- acceptArgs ustk ua
      bstk <- acceptArgs bstk ba
      eval unmask env denv ustk bstk k entry
    | otherwise -> do
      (useg, bseg) <- closeArgs ustk bstk useg bseg args
      ustk <- discardFrame ustk
      bstk <- discardFrame bstk
      bstk <- bump bstk
      poke bstk $ PAp comb useg bseg
      yield unmask env denv ustk bstk k
   where
   uac = asize ustk + ucount args + uscount useg
   bac = asize bstk + bcount args + bscount bseg
  _ -> die "applying non-function"
{-# inline apply #-}

jump
  :: Unmask -> Env -> DEnv -> Stack 'UN -> Stack 'BX -> K
  -> Args -> Closure -> IO ()
jump unmask !env !denv !ustk !bstk !k !args clo = case clo of
  Captured sk useg bseg -> do
    (useg, bseg) <- closeArgs ustk bstk useg bseg args
    ustk <- discardFrame ustk
    bstk <- discardFrame bstk
    ustk <- dumpSeg ustk useg . F $ ucount args
    bstk <- dumpSeg bstk bseg . F $ bcount args
    repush unmask env ustk bstk denv sk k
  _ -> die "jump: non-cont"
{-# inline jump #-}

repush
  :: Unmask -> Env -> Stack 'UN -> Stack 'BX -> DEnv -> K -> K -> IO ()
repush unmask !env !ustk !bstk = go
 where
 go !denv KE !k = yield unmask env denv ustk bstk k
 go !denv (Mark ps cs sk) !k = go denv' sk $ Mark ps cs' k
  where
  denv' = cs <> EC.withoutKeys denv ps
  cs' = EC.restrictKeys denv ps
 go !denv (Push un bn ua ba nx sk) !k
   = go denv sk $ Push un bn ua ba nx k
 go !_    (CB _) !_ = die "repush: impossible"
{-# inline repush #-}

moveArgs
  :: Stack 'UN -> Stack 'BX
  -> Args -> IO (Stack 'UN, Stack 'BX)
moveArgs !ustk !bstk ZArgs = do
  ustk <- discardFrame ustk
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (UArg1 i) = do
  ustk <- prepareArgs ustk (Arg1 i)
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (UArg2 i j) = do
  ustk <- prepareArgs ustk (Arg2 i j)
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (UArgR i l) = do
  ustk <- prepareArgs ustk (ArgR i l)
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArg1 i) = do
  ustk <- discardFrame ustk
  bstk <- prepareArgs bstk (Arg1 i)
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArg2 i j) = do
  ustk <- discardFrame ustk
  bstk <- prepareArgs bstk (Arg2 i j)
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArgR i l) = do
  ustk <- discardFrame ustk
  bstk <- prepareArgs bstk (ArgR i l)
  pure (ustk, bstk)
moveArgs !ustk !bstk (DArg2 i j) = do
  ustk <- prepareArgs ustk (Arg1 i)
  bstk <- prepareArgs bstk (Arg1 j)
  pure (ustk, bstk)
moveArgs !ustk !bstk (DArgR ui ul bi bl) = do
  ustk <- prepareArgs ustk (ArgR ui ul)
  bstk <- prepareArgs bstk (ArgR bi bl)
  pure (ustk, bstk)
moveArgs !ustk !bstk (UArgN as) = do
  ustk <- prepareArgs ustk (ArgN as)
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArgN as) = do
  bstk <- prepareArgs bstk (ArgN as)
  pure (ustk, bstk)
moveArgs !ustk !bstk (DArgN us bs) = do
  ustk <- prepareArgs ustk (ArgN us)
  bstk <- prepareArgs bstk (ArgN bs)
  pure (ustk, bstk)
{-# inline moveArgs #-}

foreignArgs :: Stack 'UN -> Stack 'BX -> Args -> IO ForeignArgs
foreignArgs !_    !_    ZArgs = pure []
foreignArgs !ustk !_    (UArg1 i) = do
  x <- peekOff ustk i
  pure [Wrap Rf.intRef x]
foreignArgs !ustk !_    (UArg2 i j) = do
  x <- peekOff ustk i
  y <- peekOff ustk j
  pure [Wrap Rf.intRef x, Wrap Rf.intRef y]
foreignArgs !_    !bstk (BArg1 i) = do
  x <- peekOff bstk i
  pure [marshalToForeign x]
foreignArgs !_    !bstk (BArg2 i j) = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  pure [marshalToForeign x, marshalToForeign y]
foreignArgs !ustk !bstk (DArg2 i j) = do
  x <- peekOff ustk i
  y <- peekOff bstk j
  pure [Wrap Rf.intRef x, marshalToForeign y]
foreignArgs !ustk !_    (UArgR ui ul) =
  for (take ul [ui..]) $ fmap (Wrap Rf.intRef) . peekOff ustk
foreignArgs !_    !bstk (BArgR bi bl) =
  for (take bl [bi..]) $ fmap marshalToForeign . peekOff bstk
foreignArgs !ustk !bstk (DArgR ui ul bi bl) = do
  uas <- for (take ul [ui..]) $ fmap (Wrap Rf.intRef) . peekOff ustk
  bas <- for (take bl [bi..]) $ fmap marshalToForeign . peekOff bstk
  pure $ uas ++ bas
foreignArgs !ustk !_    (UArgN us) =
  for (PA.primArrayToList us) $ fmap (Wrap Rf.intRef) . peekOff ustk
foreignArgs !_    !bstk (BArgN bs) = do
  for (PA.primArrayToList bs) $ fmap (Wrap Rf.intRef) . peekOff bstk
foreignArgs !ustk !bstk (DArgN us bs) = do
  uas <- for (PA.primArrayToList us) $
           fmap (Wrap Rf.intRef) . peekOff ustk
  bas <- for (PA.primArrayToList bs) $
           fmap (marshalToForeign) . peekOff bstk
  pure $ uas ++ bas

foreignCatch
  :: (IO ForeignRslt -> IO ForeignRslt)
  -> Stack 'UN -> Stack 'BX
  -> (ForeignArgs -> IO ForeignRslt)
  -> ForeignArgs
  -> IO (Stack 'UN, Stack 'BX)
foreignCatch unmask ustk bstk f args
    = try (unmask $ f args)
  >>= foreignResult ustk bstk . encodeExn
  where
  encodeExn :: Either IOError ForeignRslt -> ForeignRslt
  encodeExn (Left e) = [Left 0, Right $ Wrap Rf.errorReference e]
  encodeExn (Right r) = Left 1 : r

foreignResult
  :: Stack 'UN -> Stack 'BX -> ForeignRslt -> IO (Stack 'UN, Stack 'BX)
foreignResult !ustk !bstk [] = pure (ustk,bstk)
foreignResult !ustk !bstk (Left i : rs) = do
  ustk <- bump ustk
  poke ustk i
  foreignResult ustk bstk rs
foreignResult !ustk !bstk (Right x : rs) = do
  bstk <- bump bstk
  poke bstk $ Foreign x
  foreignResult ustk bstk rs

buildData
  :: Stack 'UN -> Stack 'BX -> Tag -> Args -> IO Closure
buildData !_    !_    !t ZArgs = pure $ Enum t
buildData !ustk !_    !t (UArg1 i) = do
  x <- peekOff ustk i
  pure $ DataU1 t x
buildData !ustk !_    !t (UArg2 i j) = do
  x <- peekOff ustk i
  y <- peekOff ustk j
  pure $ DataU2 t x y
buildData !_    !bstk !t (BArg1 i) = do
  x <- peekOff bstk i
  pure $ DataB1 t x
buildData !_    !bstk !t (BArg2 i j) = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  pure $ DataB2 t x y
buildData !ustk !bstk !t (DArg2 i j) = do
  x <- peekOff ustk i
  y <- peekOff bstk j
  pure $ DataUB t x y
buildData !ustk !_    !t (UArgR i l) = do
  useg <- augSeg ustk unull (ArgR i l)
  pure $ DataG t useg bnull
buildData !_    !bstk !t (BArgR i l) = do
  bseg <- augSeg bstk bnull (ArgR i l)
  pure $ DataG t unull bseg
buildData !ustk !bstk !t (DArgR ui ul bi bl) = do
  useg <- augSeg ustk unull (ArgR ui ul)
  bseg <- augSeg bstk bnull (ArgR bi bl)
  pure $ DataG t useg bseg
buildData !ustk !_    !t (UArgN as) = do
  useg <- augSeg ustk unull (ArgN as)
  pure $ DataG t useg bnull
buildData !_    !bstk !t (BArgN as) = do
  bseg <- augSeg bstk bnull (ArgN as)
  pure $ DataG t unull bseg
buildData !ustk !bstk !t (DArgN us bs) = do
  useg <- augSeg ustk unull (ArgN us)
  bseg <- augSeg bstk bnull (ArgN bs)
  pure $ DataG t useg bseg
{-# inline buildData #-}

dumpData
  :: Stack 'UN -> Stack 'BX -> Closure -> IO (Stack 'UN, Stack 'BX)
dumpData !ustk !bstk (Enum t) = do
  ustk <- bump ustk
  pokeN ustk $ maskTag t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataU1 t x) = do
  ustk <- bumpn ustk 2
  pokeOff ustk 1 x
  pokeN ustk $ maskTag t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataU2 t x y) = do
  ustk <- bumpn ustk 3
  pokeOff ustk 2 y
  pokeOff ustk 1 x
  pokeN ustk $ maskTag t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataB1 t x) = do
  ustk <- bump ustk
  bstk <- bump bstk
  poke bstk x
  pokeN ustk $ maskTag t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataB2 t x y) = do
  ustk <- bump ustk
  bstk <- bumpn bstk 2
  pokeOff bstk 1 y
  poke bstk x
  pokeN ustk $ maskTag t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataUB t x y) = do
  ustk <- bumpn ustk 2
  bstk <- bump bstk
  pokeOff ustk 1 x
  poke bstk y
  pokeN ustk $ maskTag t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataG t us bs) = do
  ustk <- dumpSeg ustk us S
  bstk <- dumpSeg bstk bs S
  ustk <- bump ustk
  pokeN ustk $ maskTag t
  pure (ustk, bstk)
dumpData !_    !_  clo = die $ "dumpData: bad closure: " ++ show clo
{-# inline dumpData #-}

-- Note: although the representation allows it, it is impossible
-- to under-apply one sort of argument while over-applying the
-- other. Thus, it is unnecessary to worry about doing tricks to
-- only grab a certain number of arguments.
closeArgs
  :: Stack 'UN -> Stack 'BX
  -> Seg 'UN -> Seg 'BX
  -> Args -> IO (Seg 'UN, Seg 'BX)
closeArgs !_    !_    !useg !bseg ZArgs = pure (useg, bseg)
closeArgs !ustk !_    !useg !bseg (UArg1 i) = do
  useg <- augSeg ustk useg (Arg1 i)
  pure (useg, bseg)
closeArgs !ustk !_    !useg !bseg (UArg2 i j) = do
  useg <- augSeg ustk useg (Arg2 i j)
  pure (useg, bseg)
closeArgs !ustk !_    !useg !bseg (UArgR i l) = do
  useg <- augSeg ustk useg (ArgR i l)
  pure (useg, bseg)
closeArgs !_    !bstk !useg !bseg (BArg1 i) = do
  bseg <- augSeg bstk bseg (Arg1 i)
  pure (useg, bseg)
closeArgs !_    !bstk !useg !bseg (BArg2 i j) = do
  bseg <- augSeg bstk bseg (Arg2 i j)
  pure (useg, bseg)
closeArgs !_    !bstk !useg !bseg (BArgR i l) = do
  bseg <- augSeg bstk bseg (ArgR i l)
  pure (useg, bseg)
closeArgs !ustk !bstk !useg !bseg (DArg2 i j) = do
  useg <- augSeg ustk useg (Arg1 i)
  bseg <- augSeg bstk bseg (Arg1 j)
  pure (useg, bseg)
closeArgs !ustk !bstk !useg !bseg (DArgR ui ul bi bl) = do
  useg <- augSeg ustk useg (ArgR ui ul)
  bseg <- augSeg bstk bseg (ArgR bi bl)
  pure (useg, bseg)
closeArgs !ustk !_    !useg !bseg (UArgN as) = do
  useg <- augSeg ustk useg (ArgN as)
  pure (useg, bseg)
closeArgs !_    !bstk !useg !bseg (BArgN as) = do
  bseg <- augSeg bstk bseg (ArgN as)
  pure (useg, bseg)
closeArgs !ustk !bstk !useg !bseg (DArgN us bs) = do
  useg <- augSeg ustk useg (ArgN us)
  bseg <- augSeg bstk bseg (ArgN bs)
  pure (useg, bseg)

peekForeign :: Stack 'BX -> Int -> IO a
peekForeign bstk i
  = peekOff bstk i >>= \case
      Foreign x -> pure $ unwrapForeign x
      _ -> die "bad foreign argument"
{-# inline peekForeign #-}

uprim1 :: Stack 'UN -> UPrim1 -> Int -> IO (Stack 'UN)
uprim1 !ustk DECI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (m-1)
  pure ustk
uprim1 !ustk INCI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (m+1)
  pure ustk
uprim1 !ustk NEGI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (-m)
  pure ustk
uprim1 !ustk SGNI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (signum m)
  pure ustk
uprim1 !ustk ABSF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (abs d)
  pure ustk
uprim1 !ustk CEIL !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (ceiling d)
  pure ustk
uprim1 !ustk FLOR !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (floor d)
  pure ustk
uprim1 !ustk TRNF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (truncate d)
  pure ustk
uprim1 !ustk RNDF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (round d)
  pure ustk
uprim1 !ustk EXPF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (exp d)
  pure ustk
uprim1 !ustk LOGF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (log d)
  pure ustk
uprim1 !ustk SQRT !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (sqrt d)
  pure ustk
uprim1 !ustk COSF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (cos d)
  pure ustk
uprim1 !ustk SINF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (sin d)
  pure ustk
uprim1 !ustk TANF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (tan d)
  pure ustk
uprim1 !ustk COSH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (cosh d)
  pure ustk
uprim1 !ustk SINH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (sinh d)
  pure ustk
uprim1 !ustk TANH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (tanh d)
  pure ustk
uprim1 !ustk ACOS !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (acos d)
  pure ustk
uprim1 !ustk ASIN !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (asin d)
  pure ustk
uprim1 !ustk ATAN !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (atan d)
  pure ustk
uprim1 !ustk ASNH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (asinh d)
  pure ustk
uprim1 !ustk ACSH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (acosh d)
  pure ustk
uprim1 !ustk ATNH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (atanh d)
  pure ustk
uprim1 !ustk ITOF !i = do
  n <- peekOff ustk i
  ustk <- bump ustk
  pokeD ustk (fromIntegral n)
  pure ustk
uprim1 !ustk NTOF !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  pokeD ustk (fromIntegral n)
  pure ustk
uprim1 !ustk LZRO !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  poke ustk (countLeadingZeros n)
  pure ustk
uprim1 !ustk TZRO !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  poke ustk (countTrailingZeros n)
  pure ustk
uprim1 !ustk COMN !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  pokeN ustk (complement n)
  pure ustk
{-# inline uprim1 #-}

uprim2 :: Stack 'UN -> UPrim2 -> Int -> Int -> IO (Stack 'UN)
uprim2 !ustk ADDI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m+n)
  pure ustk
uprim2 !ustk SUBI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m-n)
  pure ustk
uprim2 !ustk MULI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m*n)
  pure ustk
uprim2 !ustk DIVI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m`div`n)
  pure ustk
uprim2 !ustk MODI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m`mod`n)
  pure ustk
uprim2 !ustk SHLI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m`shiftL`n)
  pure ustk
uprim2 !ustk SHRI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m`shiftR`n)
  pure ustk
uprim2 !ustk SHRN !i !j = do
  m <- peekOffN ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  pokeN ustk (m`shiftR`n)
  pure ustk
uprim2 !ustk POWI !i !j = do
  m <- peekOff ustk i
  n <- peekOffN ustk j
  ustk <- bump ustk
  poke ustk (m^n)
  pure ustk
uprim2 !ustk EQLI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk $ if m == n then 1 else 0
  pure ustk
uprim2 !ustk LEQI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk $ if m <= n then 1 else 0
  pure ustk
uprim2 !ustk LEQN !i !j = do
  m <- peekOffN ustk i
  n <- peekOffN ustk j
  ustk <- bump ustk
  poke ustk $ if m <= n then 1 else 0
  pure ustk
uprim2 !ustk ADDF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x + y)
  pure ustk
uprim2 !ustk SUBF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x - y)
  pure ustk
uprim2 !ustk MULF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x * y)
  pure ustk
uprim2 !ustk DIVF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x / y)
  pure ustk
uprim2 !ustk LOGB !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (logBase x y)
  pure ustk
uprim2 !ustk POWF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x ** y)
  pure ustk
uprim2 !ustk MAXF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (max x y)
  pure ustk
uprim2 !ustk MINF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (min x y)
  pure ustk
uprim2 !ustk EQLF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (if x == y then 1 else 0)
  pure ustk
uprim2 !ustk LEQF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (if x <= y then 1 else 0)
  pure ustk
uprim2 !ustk ATN2 !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (atan2 x y)
  pure ustk
uprim2 !ustk ANDN !i !j = do
  x <- peekOffN ustk i
  y <- peekOffN ustk j
  ustk <- bump ustk
  pokeN ustk (x .&. y)
  pure ustk
uprim2 !ustk IORN !i !j = do
  x <- peekOffN ustk i
  y <- peekOffN ustk j
  ustk <- bump ustk
  pokeN ustk (x .|. y)
  pure ustk
uprim2 !ustk XORN !i !j = do
  x <- peekOffN ustk i
  y <- peekOffN ustk j
  ustk <- bump ustk
  pokeN ustk (xor x y)
  pure ustk
{-# inline uprim2 #-}

bprim1
  :: Stack 'UN -> Stack 'BX -> BPrim1 -> Int
  -> IO (Stack 'UN, Stack 'BX)
bprim1 !ustk !bstk SIZT i = do
  t <- peekOffT bstk i
  ustk <- bump ustk
  poke ustk $ Tx.length t
  pure (ustk, bstk)
bprim1 !ustk !bstk ITOT i = do
  n <- peekOff ustk i
  bstk <- bump bstk
  pokeT bstk . Tx.pack $ show n
  pure (ustk, bstk)
bprim1 !ustk !bstk NTOT i = do
  n <- peekOffN ustk i
  bstk <- bump bstk
  pokeT bstk . Tx.pack $ show n
  pure (ustk, bstk)
bprim1 !ustk !bstk FTOT i = do
  f <- peekOffD ustk i
  bstk <- bump bstk
  pokeT bstk . Tx.pack $ show f
  pure (ustk, bstk)
bprim1 !ustk !bstk USNC i
  = peekOffT bstk i >>= \t -> case Tx.unsnoc t of
      Nothing -> do
        ustk <- bump ustk
        poke ustk 0
        pure (ustk, bstk)
      Just (t, c) -> do
        ustk <- bumpn ustk 2
        bstk <- bump bstk
        pokeOff ustk 1 $ fromEnum c
        poke ustk 1
        pokeT bstk t
        pure (ustk, bstk)
bprim1 !ustk !bstk UCNS i
  = peekOffT bstk i >>= \t -> case Tx.uncons t of
      Nothing -> do
        ustk <- bump ustk
        poke ustk 0
        pure (ustk, bstk)
      Just (c, t) -> do
        ustk <- bumpn ustk 2
        bstk <- bump bstk
        pokeOff ustk 1 $ fromEnum c
        poke ustk 1
        pokeT bstk t
        pure (ustk, bstk)
bprim1 !ustk !bstk TTOI i
  = peekOffT bstk i >>= \t -> case readm $ Tx.unpack t of
      Nothing -> do
        ustk <- bump ustk
        poke ustk 0
        pure (ustk, bstk)
      Just n -> do
        ustk <- bumpn ustk 2
        poke ustk 1
        pokeOff ustk 1 n
        pure (ustk, bstk)
  where
  readm ('+':s) = readMaybe s
  readm s = readMaybe s
bprim1 !ustk !bstk TTON i
  = peekOffT bstk i >>= \t -> case readMaybe $ Tx.unpack t of
      Nothing -> do
        ustk <- bump ustk
        poke ustk 0
        pure (ustk, bstk)
      Just n -> do
        ustk <- bumpn ustk 2
        poke ustk 1
        pokeOffN ustk 1 n
        pure (ustk, bstk)
bprim1 !ustk !bstk TTOF i
  = peekOffT bstk i >>= \t -> case readMaybe $ Tx.unpack t of
      Nothing -> do
        ustk <- bump ustk
        poke ustk 0
        pure (ustk, bstk)
      Just f -> do
        ustk <- bumpn ustk 2
        poke ustk 1
        pokeOffD ustk 1 f
        pure (ustk, bstk)
{-# inline bprim1 #-}

bprim2
  :: Stack 'UN -> Stack 'BX -> BPrim2 -> Int -> Int
  -> IO (Stack 'UN, Stack 'BX)
bprim2 !ustk !bstk EQLU i j = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  ustk <- bump ustk
  poke ustk $ if x == y then 1 else 0
  pure (ustk, bstk)
bprim2 !ustk !bstk LEQU i j = do
  _ <- peekOff bstk i
  _ <- peekOff bstk j
  error "LEQU not implemented"
  pure (ustk, bstk)
bprim2 !ustk !bstk DRPT i j = do
  n <- peekOff ustk i
  t <- peekOffT bstk j
  bstk <- bump bstk
  pokeT bstk $ Tx.drop n t
  pure (ustk, bstk)
bprim2 !ustk !bstk CATT i j = do
  x <- peekOffT bstk i
  y <- peekOffT bstk j
  bstk <- bump bstk
  pokeT bstk $ Tx.append x y
  pure (ustk, bstk)
bprim2 !ustk !bstk TAKT i j = do
  n <- peekOff ustk i
  t <- peekOffT bstk j
  bstk <- bump bstk
  pokeT bstk $ Tx.take n t
  pure (ustk, bstk)
bprim2 !ustk !bstk EQLT i j = do
  x <- peekOffT bstk i
  y <- peekOffT bstk j
  ustk <- bump ustk
  poke ustk $ if x == y then 1 else 0
  pure (ustk, bstk)
bprim2 !ustk !bstk LEQT i j = do
  x <- peekOffT bstk i
  y <- peekOffT bstk j
  ustk <- bump ustk
  poke ustk $ if x <= y then 1 else 0
  pure (ustk, bstk)
bprim2 !ustk !bstk LEST i j = do
  x <- peekOffT bstk i
  y <- peekOffT bstk j
  ustk <- bump ustk
  poke ustk $ if x < y then 1 else 0
  pure (ustk, bstk)
{-# inline bprim2 #-}

yield :: Unmask -> Env -> DEnv -> Stack 'UN -> Stack 'BX -> K -> IO ()
yield unmask !env !denv !ustk !bstk !k = leap denv k
 where
 leap !denv (Mark ps cs k) = leap (cs <> EC.withoutKeys denv ps) k
 leap !denv (Push ufsz bfsz uasz basz nx k) = do
   ustk <- restoreFrame ustk ufsz uasz
   bstk <- restoreFrame bstk bfsz basz
   eval unmask env denv ustk bstk k nx
 leap _ (CB (Hook f)) = f ustk bstk
 leap _ KE = pure ()
{-# inline yield #-}

selectTextBranch
  :: Tx.Text -> Section -> M.Map Tx.Text Section -> Section
selectTextBranch t df cs = M.findWithDefault df t cs
{-# inline selectTextBranch #-}

selectBranch :: Tag -> Branch -> Section
selectBranch t (Test1 u y n)
  | t == u    = y
  | otherwise = n
selectBranch t (Test2 u cu v cv e)
  | t == u    = cu
  | t == v    = cv
  | otherwise = e
selectBranch t (TestW df cs) = lookupWithDefault df t cs
selectBranch _ (TestT {}) = error "impossible"
{-# inline selectBranch #-}

splitCont
  :: DEnv -> Stack 'UN -> Stack 'BX -> K
  -> Word64 -> IO (K, DEnv, Stack 'UN, Stack 'BX, Seg 'UN, Seg 'BX, K)
splitCont !denv !ustk !bstk !k !p
  = walk denv (asize ustk) (asize bstk) KE k
 where
 walk !denv !usz !bsz !ck KE
   = die "fell off stack" >> finish denv usz bsz ck KE
 walk !denv !usz !bsz !ck (CB _)
   = die "fell off stack" >> finish denv usz bsz ck KE
 walk !denv !usz !bsz !ck (Mark ps cs k)
   | EC.member p ps = finish denv' usz bsz ck k
   | otherwise      = walk denv' usz bsz (Mark ps cs' ck) k
  where
  denv' = cs <> EC.withoutKeys denv ps
  cs' = EC.restrictKeys denv ps
 walk !denv !usz !bsz !ck (Push un bn ua ba br k)
   = walk denv (usz+un+ua) (bsz+bn+ba) (Push un bn ua ba br ck) k

 finish !denv !usz !bsz !ck !k = do
   (useg, ustk) <- grab ustk usz
   (bseg, bstk) <- grab bstk bsz
   return (ck, denv, ustk, bstk, useg, bseg, k)
{-# inline splitCont #-}

discardCont
  :: DEnv -> Stack 'UN -> Stack 'BX -> K
  -> Word64 -> IO (DEnv, Stack 'UN, Stack 'BX, K)
discardCont denv ustk bstk k p
    = splitCont denv ustk bstk k p
  <&> \(_, denv, ustk, bstk, _, _, k) -> (denv, ustk, bstk, k)
{-# inline discardCont #-}

resolve :: Env -> DEnv -> Stack 'UN -> Stack 'BX -> Ref -> IO Closure
resolve env _ _ _ (Env i) = return $ PAp (IC i $ env i) unull bnull
resolve _ _ _ bstk (Stk i) = peekOff bstk i
resolve _ denv _ _ (Dyn i) = case EC.lookup i denv of
  Just clo -> pure clo
  _ -> die $ "resolve: looked up bad dynamic: " ++ show i
