-- | Install answers + validation + rendering of @nix/settings.nix@.
-- Faithful Haskell port of @rust/installer-tui/src/config.rs@.
--
-- 'settingsNix' emits the EXACT 9-key Nix record the flake consumes on the
-- target; the @userPassword@ is NEVER written to it (only to @secrets.nix@,
-- see "Dots.Installer.Install"). The four validators produce the exact Rust
-- error strings so the parity tests pass.
module Dots.Installer.Config
  ( InstallConfig (..)
  , settingsNix
  , nixEscape
  , validateHostname
  , validateUsername
  , validateGitName
  , validateGitEmail
  , reservedUsernames
  ) where

-- | The full set of install answers. 'icUserPassword' is carried here so
-- 'Dots.Installer.Install.plan' can seed @secrets.nix@, but it is NEVER
-- rendered by 'settingsNix'. AI toggles default to 'True' (set in
-- 'Dots.Installer.App.appNew', NOT via a 'Default' — a 'Default' would flip
-- them to 'False').
data InstallConfig = InstallConfig
  { icDisks :: ![String]
  -- ^ Target disks spanning the LVM volume group (≥1). disko.nix puts a PV on
  -- each and builds @tokyonightvg@ across them.
  , icHostname :: !String
  , icUsername :: !String
  , icGitName :: !String
  -- ^ Git identity consumed by nix/home/git.nix via dots.gitName.
  , icGitEmail :: !String
  -- ^ Git identity consumed by nix/home/git.nix via dots.gitEmail.
  , icUserPassword :: !String
  , icSwapSizeGib :: !Integer
  , icAiClaude :: !Bool
  , icAiCodex :: !Bool
  , icAiOllama :: !Bool
  }
  deriving (Show, Eq)

-- | Render the nix/settings.nix the flake consumes on the target. Exactly 9
-- keys in this order: username, hostname, disks, swapSize, gitName, gitEmail,
-- aiClaude, aiCodex, aiOllama. The trailing newline matches the Rust format
-- string. Booleans render as Nix @true@/@false@.
settingsNix :: InstallConfig -> String
settingsNix cfg =
  let disks = unwords (map (\d -> "\"" <> d <> "\"") (icDisks cfg))
   in concat
        [ "{\n"
        , "  username = \"" <> icUsername cfg <> "\";\n"
        , "  hostname = \"" <> icHostname cfg <> "\";\n"
        , "  disks = [ " <> disks <> " ];\n"
        , "  swapSize = \"" <> show (icSwapSizeGib cfg) <> "G\";\n"
        , "  gitName = \"" <> nixEscape (icGitName cfg) <> "\";\n"
        , "  gitEmail = \"" <> nixEscape (icGitEmail cfg) <> "\";\n"
        , "  aiClaude = " <> boolNix (icAiClaude cfg) <> ";\n"
        , "  aiCodex = " <> boolNix (icAiCodex cfg) <> ";\n"
        , "  aiOllama = " <> boolNix (icAiOllama cfg) <> ";\n"
        , "}\n"
        ]
  where
    boolNix True = "true"
    boolNix False = "false"

-- | Escape a string for safe interpolation into a Nix double-quoted string.
-- Backslash and double-quote are the only characters that need escaping in a
-- Nix @"..."@ literal; everything else (including @$@, which has no special
-- meaning inside Nix double quotes) passes through verbatim. Backslash is
-- escaped FIRST, then the quote (so a literal backslash isn't re-escaped by
-- the quote pass).
nixEscape :: String -> String
nixEscape = escapeQuote . escapeBackslash
  where
    escapeBackslash = concatMap (\c -> if c == '\\' then "\\\\" else [c])
    escapeQuote = concatMap (\c -> if c == '"' then "\\\"" else [c])

-- | RFC 1123 host label: lowercase alphanumerics and inner hyphens, 1-63 chars.
validateHostname :: String -> Either String ()
validateHostname s
  | null s = Left "hostname must not be empty"
  | length s > 63 = Left "hostname must be at most 63 characters"
  | startsWithHyphen s || endsWithHyphen s =
      Left "hostname must not start or end with '-'"
  | not (all isHostChar s) = Left "hostname may only contain a-z, 0-9 and '-'"
  | otherwise = Right ()
  where
    isHostChar c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
    startsWithHyphen (c : _) = c == '-'
    startsWithHyphen [] = False
    endsWithHyphen [] = False
    endsWithHyphen xs = last xs == '-'

-- | Login names reserved by the system — accepting one would shadow a real
-- system account. Mirrors the Rust @RESERVED_USERNAMES@ constant.
reservedUsernames :: [String]
reservedUsernames = ["root", "nixos", "nobody", "daemon", "messagebus"]

-- | POSIX-ish login name: starts [a-z_], then [a-z0-9_-], max 31 chars.
validateUsername :: String -> Either String ()
validateUsername s
  | null s = Left "username must not be empty"
  | length s > 31 = Left "username must be at most 31 characters"
  | not (startsValid s) = Left "username must start with a-z or '_'"
  | not (all isUserChar s) = Left "username may only contain a-z, 0-9, '_' and '-'"
  | s `elem` reservedUsernames = Left "'" <> s <> "' is a reserved name"
  | otherwise = Right ()
  where
    startsValid [] = False
    startsValid (c : _) = (c >= 'a' && c <= 'z') || c == '_'
    isUserChar c =
      (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'

-- | Git user.name: non-empty, ≤ 128 chars, no newlines. Git itself is
-- permissive, so this only rejects the obviously useless values that would
-- produce broken commit metadata. 'length' on a Haskell 'String' counts
-- 'Char's (matching the Rust @chars().count()@), not bytes.
validateGitName :: String -> Either String ()
validateGitName s
  | null s = Left "git name must not be empty"
  | any isNewline s = Left "git name must not contain newlines"
  | length s > 128 = Left "git name must be at most 128 characters"
  | all isSpace s = Left "git name must not be only whitespace"
  | otherwise = Right ()
  where
    isNewline c = c == '\n' || c == '\r'

-- | Git user.email: non-empty, single @\@@, non-empty local and domain parts,
-- domain contains at least one @\.@. A pragmatic subset of RFC 5321 — good
-- enough to catch typos without dragging in a full email parser.
validateGitEmail :: String -> Either String ()
validateGitEmail s
  | null s = Left "git email must not be empty"
  | any isSpace s = Left "git email must not contain whitespace"
  | otherwise = case breakOnAt s of
      Nothing -> Left "git email must contain exactly one '@'"
      Just (local, domain)
        | length (filter (== '@') s) /= 1 ->
            Left "git email must contain exactly one '@'"
        | null local -> Left "git email local part must not be empty"
        | null domain -> Left "git email domain must not be empty"
        | not (elem '.' domain) -> Left "git email domain must contain a '.'"
        | otherwise -> Right ()

-- | Split on the first @\@@. 'Nothing' if there is no @\@@.
breakOnAt :: String -> Maybe (String, String)
breakOnAt = go []
  where
    go _ [] = Nothing
    go acc ('@' : rest) = Just (reverse acc, rest)
    go acc (c : rest) = go (c : acc) rest

-- | Local 'isSpace' (the Rust uses @char::is_whitespace@, which for the
-- relevant inputs agrees with this set).
isSpace :: Char -> Bool
isSpace c =
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'