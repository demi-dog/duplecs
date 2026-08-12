-- ambient globals for `luau-lsp analyze`: duplecs targets Roblox and Lune,
-- which both provide `warn`, but standard Luau analysis does not.
declare function warn<T...>(...: T...): ()
