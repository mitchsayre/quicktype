module IRGraph
    ( IRGraph(..)
    , IRClassData(..)
    , IRType(..)
    , Entry(..)
    , removeElement
    , emptyGraph
    , followIndex
    , getClassFromGraph
    , lookupOrDefault
    , decomposeTypeSet
    , nullifyNothing
    , replaceClassesInType
    , setFromType
    , matchingProperties
    , mapClasses
    , combineNames
    , classesInGraph
    , regatherClassNames
    , transformNames
    , filterTypes
    ) where

import Prelude

import Data.Array.Partial (last)
import Data.Char.Unicode (isPunctuation)
import Data.Either.Nested (in1)
import Data.Foldable (find, all, any)
import Data.List (List, concatMap, fromFoldable, singleton, (:))
import Data.List as L
import Data.Map (Map, values)
import Data.Map as M
import Data.Maybe (Maybe(..), fromJust, maybe, fromMaybe)
import Data.Sequence as Seq
import Data.Set (Set, empty, insert, member)
import Data.Set as S
import Data.String.Util (singular)
import Data.Tuple (Tuple(..))
import Data.Tuple as T
import Partial.Unsafe (unsafePartial)

data Entry
    = NoType
    | Class IRClassData
    | Redirect Int

newtype IRGraph = IRGraph { classes :: Seq.Seq Entry, toplevel :: IRType }

newtype IRClassData = IRClassData { names :: Set String, properties :: Map String IRType }

data IRType
    = IRNothing
    | IRNull
    | IRInteger
    | IRDouble
    | IRBool
    | IRString
    | IRArray IRType
    | IRClass Int
    | IRMap IRType
    | IRUnion (Set IRType)

derive instance eqEntry :: Eq Entry
derive instance eqIRType :: Eq IRType
derive instance ordIRType :: Ord IRType
derive instance eqIRClassData :: Eq IRClassData

makeClass :: String -> Map String IRType -> IRClassData
makeClass name properties = IRClassData { names: S.singleton name, properties }

emptyGraph :: IRGraph
emptyGraph = IRGraph { classes: Seq.empty, toplevel: IRNothing }

followIndex :: IRGraph -> Int -> Tuple Int IRClassData
followIndex graph@(IRGraph { classes }) index =
    unsafePartial $
        case fromJust $ Seq.index index classes of
        Class cd -> Tuple index cd
        Redirect i -> followIndex graph i

getClassFromGraph :: IRGraph -> Int -> IRClassData
getClassFromGraph graph index = T.snd $ followIndex graph index

mapClasses :: forall a. (Int -> IRClassData -> a) -> IRGraph -> List a
mapClasses f (IRGraph { classes }) = L.concat $ L.mapWithIndex mapper (L.fromFoldable classes)
    where
        mapper _ NoType = L.Nil
        mapper _ (Redirect _) = L.Nil
        mapper i (Class cd) = (f i cd) : L.Nil

classesInGraph :: IRGraph -> List (Tuple Int IRClassData)
classesInGraph  = mapClasses Tuple

-- FIXME: doesn't really belong here
lookupOrDefault :: forall k v. Ord k => v -> k -> Map k v -> v
lookupOrDefault default key m = maybe default id $ M.lookup key m

-- FIXME: doesn't really belong here
removeElement :: forall a. Ord a => (a -> Boolean) -> S.Set a -> { element :: Maybe a, rest :: S.Set a }
removeElement p s = { element, rest: maybe s (\x -> S.delete x s) element }
    where element = find p s 

isArray :: IRType -> Boolean
isArray (IRArray _) = true
isArray _ = false

isClass :: IRType -> Boolean
isClass (IRClass _) = true
isClass _ = false

isMap :: IRType -> Boolean
isMap (IRMap _) = true
isMap _ = false

-- FIXME: this is horribly inefficient
decomposeTypeSet :: S.Set IRType -> { maybeArray :: Maybe IRType, maybeClass :: Maybe IRType, maybeMap :: Maybe IRType, rest :: S.Set IRType }
decomposeTypeSet s =
    let { element: maybeArray, rest: rest } = removeElement isArray s
        { element: maybeClass, rest: rest } = removeElement isClass rest
        { element: maybeMap, rest: rest } = removeElement isMap rest
    in { maybeArray, maybeClass, maybeMap, rest }

setFromType :: IRType -> S.Set IRType
setFromType IRNothing = S.empty
setFromType x = S.singleton x

nullifyNothing :: IRType -> IRType
nullifyNothing IRNothing = IRNull
nullifyNothing x = x

matchingProperties :: forall v. Eq v => Map String v -> Map String v -> Map String v
matchingProperties ma mb = M.fromFoldable $ L.concatMap getFromB (M.toUnfoldable ma)
    where
        getFromB (Tuple k va) =
            case M.lookup k mb of
            Just vb | va == vb -> Tuple k vb : L.Nil
                    | otherwise -> L.Nil
            Nothing -> L.Nil

propertiesAreSubset :: IRGraph -> Map String IRType -> Map String IRType -> Boolean
propertiesAreSubset graph ma mb = all isInB (M.toUnfoldable ma :: List _)
    where isInB (Tuple n ta) = maybe false (isSubtypeOf graph ta) (M.lookup n mb)

isMaybeSubtypeOfMaybe :: IRGraph -> Maybe IRType -> Maybe IRType -> Boolean
isMaybeSubtypeOfMaybe _ Nothing Nothing = true
isMaybeSubtypeOfMaybe graph (Just a) (Just b) = isSubtypeOf graph a b
isMaybeSubtypeOfMaybe _ _ _ = false

isSubtypeOf :: IRGraph ->  IRType -> IRType -> Boolean
isSubtypeOf _ IRNothing _ = true
isSubtypeOf graph (IRUnion sa) (IRUnion sb) = all (\ta -> any (isSubtypeOf graph ta) sb) sa
isSubtypeOf graph (IRArray a) (IRArray b) = isSubtypeOf graph a b
isSubtypeOf graph (IRMap a) (IRMap b) = isSubtypeOf graph a b
isSubtypeOf graph (IRClass ia) (IRClass ib) =
    let IRClassData { properties: pa } = getClassFromGraph graph ia
        IRClassData { properties: pb } = getClassFromGraph graph ib
    in propertiesAreSubset graph pa pb
isSubtypeOf _ a b = a == b

replaceClassesInType :: (Int -> Maybe IRType) -> IRType -> IRType
replaceClassesInType replacer t =
    case t of
    IRClass i -> fromMaybe t $ replacer i
    IRArray a -> IRArray $ replaceClassesInType replacer a
    IRMap m -> IRMap $ replaceClassesInType replacer m
    IRUnion s -> IRUnion $ S.map (replaceClassesInType replacer) s
    _ -> t

regatherClassNames :: IRGraph -> IRGraph
regatherClassNames graph@(IRGraph { classes, toplevel }) =
    IRGraph { classes: Seq.fromFoldable $ L.mapWithIndex entryMapper $ L.fromFoldable classes, toplevel }
    where
        newNames = combine $ mapClasses gatherFromClassData graph
        entryMapper :: Int -> Entry -> Entry
        entryMapper i entry =
            case entry of
            Class (IRClassData { names, properties }) -> Class $ IRClassData { names: fromMaybe names (M.lookup i newNames), properties}
            _ -> entry
        gatherFromClassData :: Int -> IRClassData -> Map Int (Set String)
        gatherFromClassData _ (IRClassData { properties }) =
            combine $ map (\(Tuple n t) -> gatherFromType n t) (M.toUnfoldable properties :: List _)
        combine :: List (Map Int (Set String)) -> Map Int (Set String)
        combine =
            L.foldr (M.unionWith S.union) M.empty
        gatherFromType :: String -> IRType -> Map Int (Set String)
        gatherFromType name t =
            case t of
            IRClass i -> M.singleton i (S.singleton name)
            IRArray a -> gatherFromType (singular name) a
            IRMap m -> gatherFromType (singular name) m
            IRUnion types -> combine $ map (gatherFromType name) (L.fromFoldable types)
            _ -> M.empty

-- FIXME: doesn't really belong here
combineNames :: S.Set String -> String
combineNames s = case L.fromFoldable s of
    L.Nil -> "NONAME"
    n : _ -> n

transformNames :: forall a b. Ord a => (b -> String) -> (String -> String) -> (Set String) -> List (Tuple a b) -> Map a String
transformNames legalize otherize illegalNames names =
    process illegalNames M.empty names
    where
        makeName :: b -> String -> Set String -> String
        makeName name tryName setSoFar =
            if S.member tryName setSoFar then
                makeName name (otherize tryName) setSoFar
            else
                tryName
        process :: (Set String) -> (Map a String) -> (List (Tuple a b)) -> (Map a String)
        process setSoFar mapSoFar l =
            case l of
            L.Nil -> mapSoFar
            (Tuple identifier inputs) : rest ->
                let name = makeName inputs (legalize inputs) setSoFar
                in
                    process (S.insert name setSoFar) (M.insert identifier name mapSoFar) rest

filterTypes :: forall a. (IRType -> Maybe a) -> IRGraph -> List a
filterTypes predicate graph@(IRGraph { classes, toplevel }) =
    filterType toplevel <> (L.concat $ mapClasses (\_ cd -> filterClass cd) graph)
    where
        filterClass :: IRClassData -> List a
        filterClass (IRClassData { properties }) =
            L.concatMap filterType $ M.values properties
        recurseType t =
            case t of
            IRArray t -> filterType t
            IRMap t -> filterType t
            IRUnion s ->
                L.concatMap filterType (L.fromFoldable s)
            _ -> L.Nil
        filterType :: IRType -> List a
        filterType t =
            let l = recurseType t
            in
                case predicate t of
                Nothing -> l
                Just x -> L.Cons x l
