-- |
-- Module      : Control.Auto.Process.Random
-- Description : Entropy generationg 'Auto's.
-- Copyright   : (c) Justin Le 2015
-- License     : MIT
-- Maintainer  : justin@jle.im
-- Stability   : unstable
-- Portability : portable
--
-- This module provides 'Auto's (purely) generating entropy in the form of
-- random or noisy processes.  Note that every 'Auto' here is completely
-- deterministic --- given the same initial seed, one would expect the same
-- stream of outputs on every run.  Furthermore, if a serializable 'Auto'
-- is serialized and resumed, it will continue along the deterministic path
-- dictated by the /original/ seed given.
--
-- All of these 'Auto's come in three flavors: one serializing one that
-- works with any serializable 'RandomGen' instance, one serializing one
-- that works specifically with 'StdGen' from "System.Random", and one that
-- takes any 'RandomGen' (including 'StdGen') and runs it without the
-- ability to serialize and resume deterministically.
--
-- The reason why there's a specialized 'StdGen' version for all of these
-- is that 'StdGen' actually doesn't have a 'Serialize' instance, so a
-- rudimentary serialization process is provded with the 'StdGen' versions.
--
-- The first class of generators take arbitrary @g -> (b, g)@ functions:
-- "Generate a random @b@, using the given function, and replace the seed
-- with the resulting seed".  Most "random" functions follow this pattern,
-- including 'random' and 'randomR', and if you are using something from
-- <http://hackage.haskell.org/package/MonadRandom MonadRandom>,
-- then you can use the 'runRand' function to turn a @'Rand' g b@ into a @g
-- -> (b, g)@, as well:
--
-- @
-- 'runRand' :: 'RandomGen' g => 'Rand' g b -> (g -> (b, g))
-- @
--
-- These are useful for generating noise...a new random value at every
-- stoep.  They are entropy sources.
--
-- Alternatively, if you want to give up parallelizability and determinism
-- and have your entire 'Auto' be sequential, you can make your entire
-- 'Auto' run under 'Rand' or 'RandT' as its internal monad, from
-- <http://hackage.haskell.org/package/MonadRandom MonadRandom>.
--
-- @
-- 'Auto' ('Rand' g) a b
-- 'Auto' ('RandT' g m) a b
-- @
--
-- In this case, if you wanted to pull a random number, you could do:
--
-- @
-- 'effect' 'random' :: ('Random' r, 'RandomGen' g) => 'Auto' ('Rand' g) a r
-- 'effect' 'random' :: ('Random' r, 'RandomGen' g) => 'Auto' ('RandT' g m) a r
-- @
--
-- Which pulls a random @r@ from "thin air" (from the internal 'Rand'
-- monad).
--
-- However, you lose a great deal of determinism from this method, as your
-- 'Auto's are no longer deterministic with a given seed...and resumability
-- becomes dependent on starting everything with the same seed every time
-- you re-load your 'Auto'.  Also, 'Auto''s are parallelizable, while
-- @'Auto' ('Rand' g)@s are not.
--
-- As a compromise, you can then "seal" away the stateful part with
-- 'sealState' and 'hoistA':
--
-- @
-- sealRandom :: 'Monad' m => 'Auto' ('RandT' g m) a b -> g -> 'Auto' m a b
-- sealRandom a0 = 'sealState' . 'hoistA' ('StateT' . 'runRandT')
--
-- sealRandom' :: 'Auto' ('Rand' g) a b -> g -> 'Auto'' a b
-- sealRandom' = sealRandom
-- @
--
-- Where 'hoistA' turns an @'Auto' ('RandT' g m)@ into an @'Auto' m@.
--
-- In this way, you can run any 'Auto' under 'Rand' or 'RandT' as if it was
-- a normal 'Auto' "without" underlying randomness.  (These functions
-- aren't given here so that this library doesn't incurr a dependency on
-- /MonadRandom/). This lets you compose your sequential/non-parallel parts
-- in 'Rand' and use it as a part of an 'Auto''.
--
-- The other generators given are for useful random processes you might run
-- into.  The first is a 'Blip' stream that emits at random times with the
-- given frequency/probability.  The second works /Interval/ semantics from
-- "Control.Auto.Interval", and is a stream that is "on" or "off", chunks
-- at a time, for random lengths.  The average length of each on or off
-- period is controlled by the parameter you pass in.
--

module Control.Auto.Process.Random (
  -- * Streams of random values from random generators
    rands
  , stdRands
  , rands_
  , randsM
  , stdRandsM
  , randsM_
  -- * Lifting/wrapping random functions
  , arrRand
  , arrRandM
  , arrRandStd
  , arrRandStdM
  , arrRand_
  , arrRandM_
  -- * Random processes
  -- ** Bernoulli (on/off) processes
  , bernoulli
  , stdBernoulli
  , bernoulli_
  -- ** Random-length intervals
  , randIntervals
  , stdRandIntervals
  , randIntervals_
  ) where

import Control.Applicative
import Control.Auto.Blip
import Control.Auto.Blip.Internal
import Control.Auto.Core
import Control.Auto.Interval
import Control.Category
import Data.Bits
import Data.Serialize
import Data.Tuple
import Prelude hiding             (id, (.), concat, concatMap, sum)
import System.Random

-- | Given a seed-consuming generating function of form @g -> (b, g)@
-- (where @g@ is the seed, and @b@ is the result) and an initial seed,
-- return an 'Auto' that continually generates random values using the
-- given generating funcion.
--
-- You'll notice that most of the useful functions from "System.Random" fit
-- this form:
--
-- @
-- 'random'  :: 'RandomGen' g =>            g -> (b, g)
-- 'randomR' :: 'RandomGen' g => (b, b) -> (g -> (b, g))
-- @
--
-- If you are using something from <http://hackage.haskell.org/package/MonadRandom MonadRandom>,
-- then you can use the 'runRand' function to turn a @'Rand' g b@ into a @g
-- -> (b, g)@:
--
-- @
-- 'runRand' :: 'RandomGen' g => 'Rand' g b -> (g -> (b, g))
-- @
--
--
-- Here is an example using 'stdRands' (for 'StdGen'), but 'rands' works
-- exactly the same way, I promise!
--
-- >>> let g = mkStdGen 8675309
-- >>> let a = stdRands (randomR (1,100)) g :: Auto' a Int
-- >>> let (res, _) = stepAutoN' 10 a ()
-- >>> res
-- [67, 15, 97, 13, 55, 12, 34, 86, 57, 42]
--
--
-- Yeah, if you are using 'StdGen' from "System.Random", you'll notice that
-- 'StdGen' has no 'Serialize' instance, so you can't use it with this; you
-- have to either use 'stdRands' or 'rands_' (if you don't want
-- serialization/resumability).
--
-- In the context of these generators, resumability basically means
-- deterministic behavior over re-loads...if "reloading", it'll ignore the
-- seed you pass in, and use the original seed given when originally saved.
--
rands :: (Serialize g, RandomGen g)
      => (g -> (b, g)) -- ^ random generating function
      -> g             -- ^ initial generator
      -> Auto m a b
rands r = mkState (\_ g -> g `seq` r g)
{-# INLINE rands #-}

-- | Like 'rands', but specialized for 'StdGen' from "System.Random", so
-- that you can serialize and resume.  This is needed because 'StdGen'
-- doesn't have a 'Serialize' instance.
--
-- See the documentation of 'rands' for more information.
--
stdRands :: (StdGen -> (b, StdGen)) -- ^ random generating function
         -> StdGen                  -- ^ initial generator
         -> Auto m a b
stdRands r = mkState' (read <$> get) (put . show) (\_ g -> r g)
{-# INLINE stdRands #-}


-- | The non-serializing/non-resuming version of 'rands'.
rands_ :: RandomGen g
       => (g -> (b, g))   -- ^ random generating function
       -> g               -- ^ initial generator
       -> Auto m a b
rands_ r = mkState_ (\_ g -> r g)
{-# INLINE rands_ #-}

-- | Like 'rands', except taking a "monadic" random seed function @g ->
-- m (b, g)@, instead of @g -> (b, g)@.  Your random generating function
-- has access to the underlying monad.
--
-- If you are using something from
-- <http://hackage.haskell.org/package/MonadRandom MonadRandom>, then you
-- can use the 'runRandT' function to turn a @'RandT' g m b@ into a @g ->
-- m (b, g)@:
--
-- @
-- 'runRandT' :: ('Monad' m, 'RandomGen' g)
--            => 'RandT' g m b -> (g -> m (b, g))
-- @
--
randsM :: (Serialize g, RandomGen g, Monad m)
       => (g -> m (b, g))
       -> g
       -> Auto m a b
randsM r = mkStateM (\_ g -> r g)
{-# INLINE randsM #-}

-- | Like 'randsM', but specialized for 'StdGen' from "System.Random", so
-- that you can serialize and resume.  This is needed because 'StdGen'
-- doesn't have a 'Serialize' instance.
--
-- See the documentation of 'randsM' for more information.
--
stdRandsM :: Monad m
          => (StdGen -> m (b, StdGen))
          -> StdGen
          -> Auto m a b
stdRandsM r = mkStateM' (read <$> get) (put . show) (\_ g -> r g)
{-# INLINE stdRandsM #-}

-- | The non-serializing/non-resuming version of 'randsM'.
randsM_ :: (RandomGen g, Monad m)
        => (g -> m (b, g))
        -> g
        -> Auto m a b
randsM_ r = mkStateM_ (\_ g -> r g)
{-# INLINE randsM_ #-}

-- | Takes a "random function", or "random arrow" --- a function taking an
-- input value and a starting seed/entropy generator and returning a result
-- and an ending seed/entropy generator --- and turns it into an 'Auto'
-- that feeds its input into such a function and outputs the result, with
-- a new seed every time.
--
-- >>> let f x = randomR (0 :: Int, x)
-- >>> streamAuto' (arrRandStd f (mkStdGen 782065)) [1..10]
-- -- [1,2,3,4,5,6,7,8,9,10] <- upper bounds
--    [1,2,0,1,5,3,7,6,8,10] -- random number from 0 to upper bound
--
-- If you are using something from
-- <http://hackage.haskell.org/package/MonadRandom MonadRandom>, then you
-- can use the @('runRand' .)@ function to turn a @a -> 'Rand' g b@ into
-- a @a -> g -> (b, g)@:
--
-- @
-- ('runRand' .) :: 'RandomGen' g => (a -> 'Rand' g b) -> (a -> g -> (b, g))
-- @
--
-- (This is basically 'mkState', specialized.)
arrRand :: (Serialize g, RandomGen g)
        => (a -> g -> (b, g))
        -> g
        -> Auto m a b
arrRand = mkState

-- | Like 'arrRand', except the result is the result of a monadic action.
-- Your random arrow function has access to the underlying monad.
--
-- If you are using something from
-- <http://hackage.haskell.org/package/MonadRandom MonadRandom>, then you
-- can use the @('runRandT' .)@ function to turn a @a -> 'RandT' m g b@
-- into a @a -> g -> m (b, g)@:
--
-- @
-- ('runRandT' .) :: 'RandomGen' g => (a -> 'RandT' g b) -> (a -> g -> m (b, g))
-- @
arrRandM :: (Monad m, Serialize g, RandomGen g)
         => (a -> g -> m (b, g))
         -> g
         -> Auto m a b
arrRandM = mkStateM

-- | Like 'arrRand', but specialized for 'StdGen' from "System.Random", so
-- that you can serialize and resume.  This is needed because 'StdGen'
-- doesn't have a 'Serialize' instance.
--
-- See the documentation of 'arrRand' for more information.
--
arrRandStd :: (a -> StdGen -> (b, StdGen))
           -> StdGen
           -> Auto m a b
arrRandStd = mkState' (read <$> get) (put . show)

-- | Like 'arrRandM', but specialized for 'StdGen' from "System.Random", so
-- that you can serialize and resume.  This is needed because 'StdGen'
-- doesn't have a 'Serialize' instance.
--
-- See the documentation of 'arrRandM' for more information.
--
arrRandStdM :: (a -> StdGen -> m (b, StdGen))
            -> StdGen
            -> Auto m a b
arrRandStdM = mkStateM' (read <$> get) (put . show)

-- | The non-serializing/non-resuming version of 'arrRand'.
arrRand_ :: RandomGen g
         => (a -> g -> (b, g))
         -> g
         -> Auto m a b
arrRand_ = mkState_

-- | The non-serializing/non-resuming version of 'arrRandM'.
arrRandM_ :: RandomGen g
          => (a -> g -> m (b, g))
          -> g
          -> Auto m a b
arrRandM_ = mkStateM_


-- | Simulates a <http://en.wikipedia.org/wiki/Bernoulli_process Bernoulli Process>:
-- a process of sequential independent trials each with a success of
-- probability @p@.
--
-- Implemented here is an 'Auto' producing a blip stream that emits
-- whenever the bernoulli process succeeds with the value of the received
-- input of the 'Auto', with its probability of succuss per each trial as
-- the 'Double' parameter.
--
-- It is expected that, for probability @p@, the stream will emit a value
-- on average once every @1/p@ ticks.
--
bernoulli :: (Serialize g, RandomGen g)
          => Double       -- ^ probability of success per step
          -> g            -- ^ initial seed
          -> Auto m a (Blip a)
bernoulli p = mkState (_bernoulliF p)

-- | Like 'bernoulli', but specialized for 'StdGen' from "System.Random",
-- so that you can serialize and resume.  This is needed because 'StdGen'
-- doesn't have a 'Serialize' instance.
--
-- See the documentation of 'bernoulli' for more information.
--
stdBernoulli :: Double    -- ^ probability of any step emitting
             -> StdGen    -- ^ initial seed
             -> Auto m a (Blip a)
stdBernoulli p = mkState' (read <$> get) (put . show) (_bernoulliF p)

-- | The non-serializing/non-resuming version of 'bernoulli'.
bernoulli_ :: RandomGen g
           => Double      -- ^ probability of any step emitting
           -> g           -- ^ initial seed
           -> Auto m a (Blip a)
bernoulli_ p = mkState_ (_bernoulliF p)

_bernoulliF :: RandomGen g
            => Double
            -> a
            -> g
            -> (Blip a, g)
_bernoulliF p x g = (outp, g')
  where
    (roll, g') = randomR (0, 1 :: Double) g
    outp | roll <= p = Blip x
         | otherwise = NoBlip

-- | An 'Interval' that is "on" and "off" for contiguous but random
-- intervals of time...when "on", allows values to pass as "on" ('Just'),
-- but when "off", suppresses all incoming values (outputing 'Nothing').
--
-- You provide a 'Double', an @l@ parameter, representing the
-- average/expected length of each on/off interval.
--
-- The distribution of interval lengths follows
-- a <http://en.wikipedia.org/wiki/Geometric_distribution Geometric Distribution>.
-- This distribution is, as we call it in maths, "memoryless", which means
-- that the "time left" that the 'Auto' will be "on" or "off" at any given
-- time is going to be, on average, the given @l@ parameter.
--
-- Internally, the "toggling" events follow a bernoulli process with a @p@
-- parameter of @1 / l@.
--
randIntervals :: (Serialize g, RandomGen g)
              => Double
              -> g
              -> Interval m a a
randIntervals l = mkState (_randIntervalsF (1/l)) . swap . random

-- | Like 'randIntervals', but specialized for 'StdGen' from
-- "System.Random", so that you can serialize and resume.  This is needed
-- because 'StdGen' doesn't have a 'Serialize' instance.
--
-- See the documentation of 'randIntervals' for more information.
--
stdRandIntervals :: Double
                 -> StdGen
                 -> Interval m a a
stdRandIntervals l = mkState' (read <$> get)
                              (put . show)
                              (_randIntervalsF (1/l))
                   . swap . random

-- | The non-serializing/non-resuming version of 'randIntervals'.
randIntervals_ :: RandomGen g
               => Double
               -> g
               -> Interval m a a
randIntervals_ l = mkState_ (_randIntervalsF (1/l)) . swap . random

_randIntervalsF :: RandomGen g
                => Double
                -> a
                -> (g, Bool)
                -> (Maybe a, (g, Bool))
_randIntervalsF thresh x (g, onoff) = (outp, (g', onoff'))
  where
    (roll, g') = randomR (0, 1 :: Double) g
    onoff' = onoff `xor` (roll <= thresh)
    outp | onoff     = Just x
         | otherwise = Nothing
    -- should this be onoff' ?

