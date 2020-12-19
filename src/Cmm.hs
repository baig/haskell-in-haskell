{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

-- | This module contains the intermediate code generator between STG and C
--
-- The reason this exists is primarily to simplify code generation. You could
-- generate C directly from STG, but this leads to more complicated code.
-- The primary mixing of concerns is that of translating the STG semantics into
-- static information, and ordering that information into actual C. For example,
-- all we need to know from a `let` binding is what kind of things get allocated,
-- and how many. If you generate C directly, you mix the calculation of this
-- information with its usage to generate C code. By separating these two parts,
-- you make both of them much simpler.
--
-- Having a separate stage makes it much easier to generate better C code, since
-- you can easily translate the STG into simple imperative statements, and then
-- analyze those to generate nicer C code.
module Cmm (Cmm (..), cmm) where

import Control.Monad.Reader
import Control.Monad.State
import qualified Data.Map.Strict as Map
import Data.Maybe (maybeToList)
import Ourlude
import STG

type PlainFunctionName = String

-- | Represents a name we can give to a function
--
-- The individual pieces of a function may not be unique,
-- but if we look at the nested tree of functions and their
-- subfunctions, then we get unique paths.
data FunctionName
  = -- | A standard function name
    PlainFunction PlainFunctionName
  | -- | A name we can use for the alternatives inside of a function
    Alts
  | -- | A name we use for the entry function
    Entry
  deriving (Show)

type Index = Int

-- | Represents what type of storage some variable will need
--
-- We can figure this out the first time a variable is used, and then
-- use that information in nested closures to figure out how they're going
-- to access this variable that they've captured
data Storage
  = -- | This variable is going to be stored locally in closures
    LocalStorage VarType
  | -- | This variable is a global function with a certain index
    --
    -- When a variable references a global function, we don't need
    -- to store it alongside the closure, since it can just reference it
    -- directly GlobalStorage Index
    GlobalStorage Index
  deriving (Eq, Show)

-- | Represents what type of variable something will end up being
data VarType
  = -- | This variable will end up being some kind of pointer
    PointerVar
  | -- | This variable will end up being a 64 bit int
    IntVar
  | -- | This variable will end up being a string
    StringVar
  deriving (Eq, Show)

-- | A location allows us to reference some value concretely
--
-- Locations tell us where exactly a variable lives. Variables of the same
-- type may live in different places in reality.
data Location
  = -- | This variable is the nth pointer arg passed to us on the stack
    Arg Index
  | -- | This variable is the nth constructor argument passed to us
    ConstructorArg Index
  | -- | This variable is the nth pointer bound in this closure
    Bound Index
  | -- | This variable is the nth int bound in this closure
    BoundInt Index
  | -- | This variable is the nth string bound in this closure
    BoundString Index
  | -- | This variable is just a global function
    Global Index
  | -- | This variable is a closure we've allocated, with the index being the sub function index
    --
    -- This can be sparse, i.e. if we have 4 subfunctions, 2 of which are global, we might
    -- have index 1 and 3 as `Allocated`.
    Allocated Index
  | -- | This variable is the nth dead pointer
    --
    -- Buried locations come from the bound names used inside the branches of a
    -- case expression. Since we split cases into two, we need a way to save
    -- and restore this before getting back to the case.
    Buried Index
  | -- | The nth dead int. See `Buried` for more information.
    BuriedInt Index
  | -- | The nth dead string. See `Buried` for more information.
    BuriedString Index
  | -- | This variable will be whatever the current function is
    CurrentNode
  | -- | This variable will be stored in the integer register
    IntRegister
  | -- | This variable will be stored in the string register
    StringRegister
  | -- | This variable is equal to this primitive int
    PrimIntLocation Int
  | -- | This variable is equal to this primitive string
    PrimStringLocation String
  deriving (Show)

-- | What type of variable is stored in this location?
locationType :: Location -> VarType
locationType = \case
  Arg _ -> PointerVar
  ConstructorArg _ -> PointerVar
  Bound _ -> PointerVar
  Global _ -> PointerVar
  Allocated _ -> PointerVar
  Buried _ -> PointerVar
  CurrentNode -> PointerVar
  BoundInt _ -> IntVar
  BuriedInt _ -> IntVar
  IntRegister -> IntVar
  PrimIntLocation _ -> IntVar
  BoundString _ -> StringVar
  BuriedString _ -> StringVar
  StringRegister -> StringVar
  PrimStringLocation _ -> StringVar

-- | Represents a kind of builtin taking two arguments
data Builtin2
  = -- | IntR <- a + b
    Add2
  | -- | IntR <- a - b
    Sub2
  | -- | IntR <- a * b
    Mul2
  | -- | IntR <- a / b
    Div2
  | -- | IntR <- a < b
    Less2
  | -- | IntR <- a <= b
    LessEqual2
  | -- | IntR <- a > b
    Greater2
  | -- | IntR <- a >= b
    GreaterEqual2
  | -- | IntR <- a == b
    EqualTo2
  | -- | IntR <- a /= b
    NotEqualTo2
  | -- | StringR <- a ++ b
    Concat2
  deriving (Show)

-- | Represents a builtin taking only a single argument
data Builtin1
  = -- | Print out an int
    PrintInt1
  | -- | Print out a string
    PrintString1
  | -- | IntR <- -a
    Negate1
  deriving (Show)

-- | Represents a single instruction in our IR
--
-- The idea is that each of these instructions is a little unit that makes
-- sense on the weird VM you need for lazy execution, and also translates
-- directly to a simple bit of C.
data Instruction
  = -- | Store a given integer into the integer register
    StoreInt Location
  | -- | Store a given string litteral into the string register
    StoreString Location
  | -- | Store a given tag into the tag register
    StoreTag Tag
  | -- | Enter the code stored at a given location
    --
    -- For this to be valid, that location needs to actually contain *code*,
    -- of course. `BoundString` would not be a valid location here, for example.
    Enter Location
  | -- | We need to enter the code for the continuation at the top of the stack
    --
    -- In practice, this stack will contain the code for the branches
    -- of a case expression, and this instruction yields control to
    -- whatever branches need to match on the value we're producing.
    EnterCaseContinuation
  | -- | Print that an error happened
    PrintError String
  | -- | Apply a builtin expecting two locations
    Builtin2 Builtin2 Location Location
  | -- | Apply a builtin expecting a single location
    Builtin1 Builtin1 Location
  | -- | Exit the program
    Exit
  | -- | Push a pointer onto the argument stack
    SAPush Location
  | -- | Push a pointer onto the stack for constructor arguments
    ConstructorArgPush Location
  | -- | Bury a pointer used in a case expression
    Bury Location
  | -- | Bury an int used in a case expression
    BuryInt Location
  | -- | Bury a string used in a case expression
    BuryString Location
  | -- | Allocate a table for a function
    --
    -- The index serves a dual purpose. It refers to the nth subfunction in whatever function
    -- this instruction appears, and lets us know which table we're referring to. This same
    -- index is also used to refer to whatever object this instruction allocates.
    AllocTable Index
  | -- | Allocate a pointer on the heap
    AllocPointer Location
  | -- | Allocate an int on the heap
    AllocInt Location
  | -- | Allocate a string on the heap
    AllocString Location
  deriving (Show)

-- | An allocation records information about how much a given expression will allocate
--
-- This is useful, because for GC purposes, we want to reserve the amount of memory
-- we need at the very start of the function, which makes it easier to not
-- have any stale pointers lying around.
data Allocation = Allocation
  { -- | The number of tables for closures allocated
    tablesAllocated :: Int,
    -- | The number of pointers inside closures allocated
    pointersAllocated :: Int,
    -- | The number of ints inside closures allocated
    intsAllocated :: Int,
    -- | The number of points to strings inside closures allocated
    stringsAllocated :: Int,
    -- | The raw strings that this function allocates
    --
    -- We need to know exactly which strings, becuase how much memory is allocated
    -- depends on the length of the string.
    primitiveStringsAllocated :: [String]
  }
  deriving (Show)

instance Semigroup Allocation where
  Allocation t p i s ps <> Allocation t' p' i' s' ps' =
    Allocation (t + t') (p + p') (i + i') (s + s') (ps <> ps')

instance Monoid Allocation where
  mempty = Allocation 0 0 0 0 []

-- | A body has some instructions, and allocation information
data Body = Body Allocation [Instruction] deriving (Show)

instance Semigroup Body where
  Body alloc1 instrs1 <> Body alloc2 instrs2 = Body (alloc1 <> alloc2) (instrs1 <> instrs2)

instance Monoid Body where
  mempty = Body mempty mempty

-- | Information we have about the arguments used in some function
--
-- We can use this to represent a couple things, namely what
-- kind of buried arguments a case expression uses, and what bound
-- arguments are used in a closure.
data ArgInfo = ArgInfo
  { -- | How many bound pointers there are
    boundPointers :: Int,
    -- | How many bound ints there are
    boundInts :: Int,
    -- | How many bound strings there are
    boundStrings :: Int
  }
  deriving (Show)

-- | Represents the body of a function.
--
-- This is either some kind of branching, or a normal function bdoy.
data FunctionBody
  = -- | A case branching on an int
    IntCaseBody ArgInfo [(Int, Body)]
  | -- | A case branching on a string
    StringCaseBody ArgInfo [(String, Body)]
  | -- | A case branching on a tag
    TagCaseBody ArgInfo [(Tag, Body)]
  | -- | Represents a normal function body
    NormalBody Body
  deriving (Show)

-- | Represents a function.
--
-- Functions are the units of execution, but have a bunch of "metadata"
-- associated with them, and can also potentially have subfunctions.
data Function = Function
  { -- | The name of the function
    functionName :: FunctionName,
    -- | If an index is present, then this function corresponds to a certain global index
    --
    -- We do things this way, that way we can traverse the function tree to build up
    -- a table of index functions to fully resolved function names. Trying
    -- to generate the fully resolved function name at this stage would be annoying.
    isGlobal :: Maybe Index,
    -- | Information about the number of pointer arguments
    --
    -- Since primitives can't be passed to functions, this just the number of pointers
    argCount :: Int,
    -- | Information about the number of bound arguments
    --
    -- This also tells us how to garbage collect the closure, along with the information
    -- about whether or not this function is global.
    boundArgs :: ArgInfo,
    -- | The actual body of this function
    body :: FunctionBody,
    -- | The functions defined nested inside of this function
    subFunctions :: [Function]
  }
  deriving (Show)

-- | A bit of CMM ast is nothing more than a list of functions, and an entry function
data Cmm = Cmm [Function] Function deriving (Show)

-- | Represents the context we use when generating Cmm
data Context = Context
  { -- | A map from names to their corresponding storages
    storages :: Map.Map ValName Storage,
    -- | A map from names to their corresponding locations
    locations :: Map.Map ValName Location,
    -- | The number of sub functions we've created so far
    --
    -- This is necessary, because if we have multiple chained expressions like `let`
    -- or `case`, then they each end up allocating sub functions, and referring
    -- to a given sub function by its *index*. Since they get merged into a single table
    -- of sub functions, we need to make sure we can refer to the correct index.
    subFunctionsCreated :: Int
  }
  deriving (Show)

-- | A default context to start with
startingContext :: Context
startingContext = Context mempty mempty 0

-- | A computation in which we have access to this context, and can make fresh variables
newtype ContextM a = ContextM (ReaderT Context (State Int) a)
  deriving (Functor, Applicative, Monad, MonadReader Context, MonadState Int)

-- | Run a contextful computation
runContextM :: ContextM a -> a
runContextM (ContextM m) = m |> (`runReaderT` startingContext) |> (`runState` 0) |> fst

-- | Generate a fresh index, that hasn't been used before
fresh :: ContextM Index
fresh = do
  current <- get
  modify' (+ 1)
  return current

-- | Run a contextual computation with some storages in scope
--
-- In case of duplicate keys, the later bindings take precedence
withStorages :: [(ValName, Storage)] -> ContextM a -> ContextM a
withStorages newStorages =
  local (\r -> r {storages = Map.fromList newStorages <> storages r})

-- | Run a contextual computation with some locations in scope
--
-- In case of duplicate keys, the later bindings take precedence
withLocations :: [(ValName, Location)] -> ContextM a -> ContextM a
withLocations newLocations =
  local (\r -> r {locations = Map.fromList newLocations <> locations r})

-- | Run a contextual computation with a certain number of tables allocated
withNMoreSubFunctions :: Int -> ContextM a -> ContextM a
withNMoreSubFunctions extra =
  local (\r -> r {subFunctionsCreated = subFunctionsCreated r + extra})

-- | Get the storage of a given name
--
-- We set things up so that a name always has a storage before we ask for it,
-- because of this, it's an *implementation error* if we can't find the storage for a name.
getStorage :: ValName -> ContextM Storage
getStorage name = asks (storages >>> Map.findWithDefault err name)
  where
    err = error ("No storage found for: " <> show name)

getLocation :: ValName -> ContextM Location
getLocation name = asks (locations >>> Map.findWithDefault err name)
  where
    err = error ("No location found for: " <> show name)

-- | Cast an atom into an Int location, panicking if this isn't possible
atomAsInt :: Atom -> ContextM Location
atomAsInt = \case
  PrimitiveAtom (PrimInt i) -> return (PrimIntLocation i)
  NameAtom n -> do
    loc <- getLocation n
    case locationType loc of
      IntVar -> return loc
      _ -> error (n <> " has location " <> show loc <> " which cannot hold an Int")
  other -> error (show other <> " cannot be used as an Int")

-- | Cast an atom into a String location, panicking if this isn't possible
atomAsString :: Atom -> ContextM Location
atomAsString = \case
  PrimitiveAtom (PrimString s) -> return (PrimStringLocation s)
  NameAtom n -> do
    loc <- getLocation n
    case locationType loc of
      StringVar -> return loc
      _ -> error (n <> " has location " <> show loc <> " which cannot hold a String")
  other -> error (show other <> " cannot be used as a String")

-- | Cast an atom into a pointer location, panicking if this isn't possible
atomAsPointer :: Atom -> ContextM Location
atomAsPointer = \case
  NameAtom n -> do
    loc <- getLocation n
    case locationType loc of
      PointerVar -> return loc
      _ -> error (n <> " has location " <> show loc <> " which cannot hold a pointer")
  other -> error (show other <> " cannot be used as a pointer")

-- | Generate the instructions for a builtin instruction
genBuiltinInstructions :: Builtin -> [Atom] -> ContextM [Instruction]
genBuiltinInstructions builtin args = case builtin of
  Add -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 Add2 l1 l2, EnterCaseContinuation]
  Sub -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 Sub2 l1 l2, EnterCaseContinuation]
  Mul -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 Mul2 l1 l2, EnterCaseContinuation]
  Div -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 Div2 l1 l2, EnterCaseContinuation]
  Less -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 Less2 l1 l2, EnterCaseContinuation]
  LessEqual -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 LessEqual2 l1 l2, EnterCaseContinuation]
  Greater -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 Greater2 l1 l2, EnterCaseContinuation]
  GreaterEqual -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 GreaterEqual2 l1 l2, EnterCaseContinuation]
  EqualTo -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 EqualTo2 l1 l2, EnterCaseContinuation]
  NotEqualTo -> do
    (l1, l2) <- grab2 atomAsInt args
    return [Builtin2 NotEqualTo2 l1 l2, EnterCaseContinuation]
  Concat -> do
    (l1, l2) <- grab2 atomAsString args
    return [Builtin2 Concat2 l1 l2, EnterCaseContinuation]
  Negate -> do
    l <- grab1 atomAsInt args
    return [Builtin1 Negate1 l, EnterCaseContinuation]
  ExitWithInt -> do
    l <- grab1 atomAsInt args
    return [Builtin1 PrintInt1 l, Exit]
  ExitWithString -> do
    l <- grab1 atomAsString args
    return [Builtin1 PrintString1 l, Exit]
  where
    grab2 :: (Atom -> ContextM Location) -> [Atom] -> ContextM (Location, Location)
    grab2 convert atoms =
      forM atoms convert >>= \case
        [l1, l2] -> return (l1, l2)
        _ -> error ("expected 2 locations for builtin " ++ show builtin ++ ", found " ++ show (length atoms))

    grab1 :: (Atom -> ContextM Location) -> [Atom] -> ContextM Location
    grab1 convert atoms =
      forM atoms convert >>= \case
        [l] -> return l
        _ -> error ("expected 1 location for builtin " <> show builtin ++ ", found " <> show (length atoms))

-- | Generate the body we need for a let expression
genLet :: [Binding] -> Expr -> ContextM (Body, [Function])
genLet bindings expr = do
  bindingStorages <- getBindingStorages
  withStorages bindingStorages <| do
    let tableCount = bindingStorages |> filter (snd >>> (== LocalStorage PointerVar)) |> length
    allocations <- getAllocations tableCount
    locations <- getLocations
    withLocations locations <| do
      subFunctions <- genSubFunctions
      letInstrs <- genLetInstrs
      let thisBody = Body allocations letInstrs
      (exprBody, exprSubFunctions) <-
        withNMoreSubFunctions (length subFunctions)
          <| genFunctionBody expr
      return (thisBody <> exprBody, subFunctions <> exprSubFunctions)
  where
    getBindingStorages :: ContextM [(ValName, Storage)]
    getBindingStorages =
      forM bindings <| \(Binding name form) -> do
        storage <- case form of
          LambdaForm [] N _ _ -> GlobalStorage <$> fresh
          _ -> return (LocalStorage PointerVar)
        return (name, storage)

    getAllocations :: Int -> ContextM Allocation
    getAllocations tableCount = do
      formAllocations <- foldMapM (\(Binding _ form) -> formAllocation form) bindings
      return (Allocation tableCount 0 0 0 [] <> formAllocations)
      where
        formAllocation :: LambdaForm -> ContextM Allocation
        formAllocation (LambdaForm bound _ _ _) = do
          (boundPtrs, boundInts, boundStrings) <- separateNames bound
          return (Allocation 0 (length boundPtrs) (length boundInts) (length boundStrings) [])

    getLocations :: ContextM [(ValName, Location)]
    getLocations = do
      start <- asks subFunctionsCreated
      forM (zip [start ..] bindings) <| \(i, Binding name _) -> do
        storage <- getStorage name
        case storage of
          GlobalStorage index -> return (name, Global index)
          LocalStorage PointerVar -> return (name, Allocated i)
          other -> error (show other <> " is not a valid storage for the closure " <> show name)

    genSubFunctions :: ContextM [Function]
    genSubFunctions = forM bindings genBinding

    genLetInstrs :: ContextM [Instruction]
    genLetInstrs = do
      start <- asks subFunctionsCreated
      foldMapM (uncurry allocateBinding) (zip [start ..] bindings)
      where
        allocateBinding :: Int -> Binding -> ContextM [Instruction]
        allocateBinding i (Binding name (LambdaForm bound _ _ _)) = do
          storage <- getStorage name
          case storage of
            GlobalStorage _ -> return []
            _ -> do
              locations <- forM bound getLocation
              let alloc typ mk = locations |> filter (locationType >>> (== typ)) |> map mk
                  allocPtrs = alloc PointerVar AllocPointer
                  allocInts = alloc IntVar AllocInt
                  allocStrings = alloc StringVar AllocString
              return ([AllocTable i] <> allocPtrs <> allocInts <> allocStrings)

-- | Generate the function body for an expression, along with the necessary sub functions
--
-- These always return normal bodies, since the case based bodies are returned
-- only in special sub functions
genFunctionBody :: Expr -> ContextM (Body, [Function])
genFunctionBody = \case
  Let bindings expr -> genLet bindings expr
  Error err ->
    return
      <| justInstructions
        [ PrintError err,
          Exit
        ]
  Primitive (PrimInt i) ->
    return
      <| justInstructions
        [ StoreInt (PrimIntLocation i),
          EnterCaseContinuation
        ]
  Primitive (PrimString s) ->
    let instrs = [StoreString (PrimStringLocation s), EnterCaseContinuation]
     in return (Body (Allocation 0 0 0 0 [s]) instrs, [])
  Box IntBox atom -> do
    loc <- atomAsInt atom
    return
      <| justInstructions
        [ StoreInt loc,
          EnterCaseContinuation
        ]
  Box StringBox atom -> do
    loc <- atomAsString atom
    return
      <| justInstructions
        [ StoreString loc,
          EnterCaseContinuation
        ]
  Apply f args -> do
    fLoc <- getLocation f
    argLocs <- mapM atomAsPointer args
    let instrs = map SAPush (reverse argLocs) <> [Enter fLoc]
    return (justInstructions instrs)
  Constructor tag args -> do
    argLocs <- mapM atomAsPointer args
    let instrs = [StoreTag tag] <> map SAPush (reverse argLocs) <> [EnterCaseContinuation]
    return (justInstructions instrs)
  Builtin b args -> do
    instrs <- genBuiltinInstructions b args
    return (justInstructions instrs)
  _ -> return (justInstructions [])
  where
    justInstructions instructions = (Body mempty instructions, [])

separateNames :: [ValName] -> ContextM ([ValName], [ValName], [ValName])
separateNames bound = do
  ptrs <- extract PointerVar
  ints <- extract IntVar
  strings <- extract StringVar
  return (ptrs, ints, strings)
  where
    extract :: VarType -> ContextM [ValName]
    extract storageType =
      filterM (getStorage >>> fmap (== LocalStorage storageType)) bound

genLamdbdaForm :: FunctionName -> Maybe Index -> LambdaForm -> ContextM Function
genLamdbdaForm functionName isGlobal (LambdaForm bound _ args expr) =
  withStorages argStorages <| do
    let argCount = length args
    (boundPtrs, boundInts, boundStrings) <- separateNames bound
    let boundArgs = ArgInfo (length boundPtrs) (length boundInts) (length boundStrings)
    myLocation <- getMyLocation functionName
    let locations =
          maybeToList myLocation
            <> boundLocations Bound boundPtrs
            <> boundLocations BoundInt boundInts
            <> boundLocations BoundString boundStrings
            <> argLocations
    (normalBody, subFunctions) <- withLocations locations (genFunctionBody expr)
    let body = NormalBody normalBody
    return Function {..}
  where
    getMyLocation :: FunctionName -> ContextM (Maybe (ValName, Location))
    getMyLocation = \case
      PlainFunction name -> do
        storage <- getStorage name
        return <| Just <| case storage of
          GlobalStorage index -> (name, Global index)
          LocalStorage PointerVar -> (name, CurrentNode)
          s -> error ("Storage " ++ show s ++ " is not a valid storage for a function")
      _ -> return Nothing

    argStorages :: [(ValName, Storage)]
    argStorages = zip args (repeat (LocalStorage PointerVar))

    argLocations :: [(ValName, Location)]
    argLocations = zip args (map Arg [0 ..])

    boundLocations :: (Int -> Location) -> [ValName] -> [(ValName, Location)]
    boundLocations f names = zip names (map f [0 ..])

genBinding :: Binding -> ContextM Function
genBinding (Binding name form) = do
  storage <- getStorage name
  let isGlobal' = case storage of
        GlobalStorage index -> Just index
        _ -> Nothing
  genLamdbdaForm (PlainFunction name) isGlobal' form

-- | Generate Cmm code from STG, in a contextful way
genCmm :: STG -> ContextM Cmm
genCmm (STG bindings entryForm) = do
  entryIndex <- fresh
  topLevel <-
    forM bindings <| \(Binding name _) -> do
      index <- fresh
      return (name, GlobalStorage index, Global index)
  let topLevelStorages = map (\(name, storage, _) -> (name, storage)) topLevel
      topLevelLocations = map (\(name, _, location) -> (name, location)) topLevel
  withStorages topLevelStorages <| withLocations topLevelLocations <| do
    entry <- genLamdbdaForm Entry (Just entryIndex) entryForm
    topLevelFunctions <- forM bindings genBinding
    return (Cmm topLevelFunctions entry)

-- | Generate Cmm code from STG
cmm :: STG -> Cmm
cmm = genCmm >>> runContextM
