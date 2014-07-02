{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}

module Control.Auto.Collection where

import Control.Applicative
import Control.Arrow
import Control.Auto.Core
import Control.Auto.Event.Internal
import Control.Monad hiding         (mapM, mapM_, sequence)
import Data.Binary
import Data.Foldable
import Data.IntMap.Strict           (IntMap)
import Data.Map.Strict              (Map)
import Data.Maybe
import Data.Monoid
import Data.Traversable
import Prelude hiding               (mapM, mapM_, concat, sequence)
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict    as M

zipAuto :: Monad m => a -> [Auto m a b] -> Auto m [a] [b]
zipAuto x0 as = mkAutoM (zipAuto x0 <$> mapM loadAuto as)
                        (mapM_ saveAuto as)
                        $ \xs -> do
                            res <- zipWithM stepAuto as (xs ++ repeat x0)
                            let ys  = map outRes  res
                                as' = map outAuto res
                            return (Output ys (zipAuto x0 as'))

-- another problem
dynZip_ :: Monad m => a -> Auto m ([a], Event [Auto m a (Maybe b)]) [b]
dynZip_ x0 = go []
  where
    go as = mkAutoM_ $ \(xs, news) -> do
                         let newas = as ++ concat news
                         res <- zipWithM stepAuto newas (xs ++ repeat x0)
                         let (ys, as') = unzip [ (y, a) | (Output (Just y) a) <- res ]
                         return (Output ys (go as'))

dynMap_ :: Monad m => a -> Auto m (IntMap a, Event [Auto m a (Maybe b)]) (IntMap b)
dynMap_ x0 = go 0 mempty
  where
    go i as = mkAutoM_ $ \(xs, news) -> do
                           let newas  = zip [i..] (concat news)
                               newas' = IM.union as (IM.fromList newas)
                               newc   = i + length newas
                               resMap = zipIntMapWithDefaults stepAuto Nothing (Just x0) newas' xs
                           res <- sequence resMap
                           let res' = IM.filter (isJust . outRes) res
                               ys   = fromJust . outRes <$> res'
                               as'  = outAuto <$> res'
                           return (Output ys (go newc as'))


mux :: forall m a b k. (Binary k, Ord k, Monad m)
    => (k -> Auto m a b)
    -> Auto m (k, a) b
mux f = fromJust <$> muxI (fmap Just . f)

mux_ :: forall m a b k. (Ord k, Monad m)
     => (k -> Auto m a b) -> Auto m (k, a) b
mux_ f = fromJust <$> muxI_ (fmap Just . f)


muxI :: forall m a b k. (Binary k, Ord k, Monad m)
     => (k -> Auto m a (Maybe b))
     -> Auto m (k, a) (Maybe b)
muxI f = go mempty
  where
    go :: Map k (Auto m a (Maybe b)) -> Auto m (k, a) (Maybe b)
    go as = mkAutoM l (s as) (t as)
    l     = do
      ks <- get
      let as' = M.fromList (map (id &&& f) ks)
      go <$> mapM loadAuto as'
    s as  = put (M.keys as) *> mapM_ saveAuto as
    t     = _muxIF f go

muxI_ :: forall m a b k. (Ord k, Monad m)
      => (k -> Auto m a (Maybe b))
      -> Auto m (k, a) (Maybe b)
muxI_ f = go mempty
  where
    go :: Map k (Auto m a (Maybe b)) -> Auto m (k, a) (Maybe b)
    go = mkAutoM_ . _muxIF f go

_muxIF :: (Ord k, Monad m)
       => (k -> Auto m a (Maybe b))
       -> (Map k (Auto m a (Maybe b)) -> Auto m (k, a) (Maybe b))
       -> Map k (Auto m a (Maybe b))
       -> (k, a)
       -> m (Output m (k, a) (Maybe b))
_muxIF f go as (k, x) = do
    let a = M.findWithDefault (f k) k as
    Output y a' <- stepAuto a x
    let as' = case y of
                Just _  -> M.insert k a' as
                Nothing -> M.delete k as
    return (Output y (go as'))





type MapMerge m k a b c = (k -> a -> b -> Maybe c) -> (m a -> m c) -> (m b -> m c) -> m a -> m b -> m c

genericZipMapWithDefaults :: (Monoid (m c), Functor m)
                          => MapMerge m k a b c
                          -> (a -> b -> c) -> Maybe a -> Maybe b
                          -> m a -> m b -> m c
genericZipMapWithDefaults mm f x0 y0 = mm f' zx zy
  where
    f' _ x y = Just (x `f` y)
    zx = case y0 of
           Nothing -> const mempty
           Just y' -> fmap (`f` y')
    zy = case x0 of
           Nothing -> const mempty
           Just x' -> fmap (x' `f`)

zipIntMapWithDefaults :: (a -> b -> c) -> Maybe a -> Maybe b -> IntMap a -> IntMap b -> IntMap c
zipIntMapWithDefaults = genericZipMapWithDefaults IM.mergeWithKey

zipMapWithDefaults :: Ord k => (a -> b -> c) -> Maybe a -> Maybe b -> Map k a -> Map k b -> Map k c
zipMapWithDefaults = genericZipMapWithDefaults M.mergeWithKey
