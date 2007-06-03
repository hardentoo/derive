
-- | Has is a pseudo derivation.  For each field of any constructor of
-- the data type, Has generates @has@/FieldName/ which returns 'True'
-- if given the the given field is a member of the constructor of the
-- passed object, and 'False' otherwise.
module Data.Derive.Has(makeHas) where

import Language.Haskell.TH.All
import Data.Char
import Data.List

{-
data Computer = Laptop {weight :: Int, memory :: Int}
              | Desktop {memory :: Int, processor :: Int}

==>

hasWeight (Laptop{}) = True
hasWeight _ = False

hasMemory (Laptop{}) = True
hasMemory (Desktop{}) = True

hasProcessor (Desktop{}) = True
hasProcessor _ = False

-}

makeHas :: Derivation
makeHas = derivation has' "Has"

has' dat = map f fields
    where
        ctors = dataCtors dat
        fields = nub $ concatMap ctorFields ctors
        
        f field = funN ("has" ++ toUpper (head field) : tail field) $
                       [sclause [RecP (mkName $ ctorName c) []] true | (True,c) <- zip matches ctors] ++
                       [sclause [WildP] false | not $ and matches]
            where
                matches = map (\c -> field `elem` ctorFields c) ctors
