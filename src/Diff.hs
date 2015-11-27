module Diff where

import Syntax
import Data.Map
import Data.Set
import Control.Monad.Free
import Patch
import Term
import Categorizable

data Annotated a annotation f = Annotated annotation (Syntax a f)
  deriving (Functor, Eq, Show)

data Range = Range { start :: Int, end :: Int }
  deriving (Eq, Show)

type Category = String
data Info = Info Range (Set Category)
  deriving (Eq, Show)

instance Categorizable Info where
  categories (Info _ c) = c

type Diff a annotation = Free (Annotated a (annotation, annotation)) (Patch (Term a annotation))

diffCost :: Diff a annotation -> Integer
diffCost f = iter (c . unwrap) $ fmap (const 1) f where
  c (Leaf _) = 0
  c (Keyed xs) = sum $ snd <$> Data.Map.toList xs
  c (Indexed xs) = sum xs
  c (Fixed xs) = sum xs
  unwrap (Annotated _ syntax) = syntax