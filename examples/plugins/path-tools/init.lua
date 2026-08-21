-- init.lua — Path Tools
-- Registers create_directory / copy_path / move_path / delete_path. Every
-- operation goes through Nova's sandboxed path validator (sanitizePath), so
-- traversal outside the project root is rejected. Prefer these over bash
-- cp/mv/rm/mkdir: `nova.run_bash` commands do pass the shell-safety
-- classifier, but that gate only blocks destructive patterns — it does not
-- confine paths, so a plain `cp` can still write outside the project root.

-- ── create_directory ────────────────────────────────────────────────

nova.register_tool({
  name = "create_directory",
  description = "Create a directory, including any necessary parent directories. Prefer this over `bash mkdir -p` — it is sandboxed and cannot escape the project root.",
  parameters = {
    path = {
      type = "string",
      description = "Directory path to create (relative to project root or absolute)",
    },
  },
  handler = function(params)
    local ok = nova.mkdir(params.path)
    if ok then
      return "Created directory: " .. params.path
    end
    return "Error: could not create directory " .. params.path
  end,
})

-- ── copy_path ───────────────────────────────────────────────────────

nova.register_tool({
  name = "copy_path",
  description = "Copy a file from source to destination. Both paths must stay inside the project root. Creates the destination file, overwriting if it exists. For copying entire directory trees, use bash with cp -r instead.",
  parameters = {
    source_path = {
      type = "string",
      description = "Source file path (relative to project root or absolute)",
    },
    destination_path = {
      type = "string",
      description = "Destination file path (relative to project root or absolute)",
    },
  },
  handler = function(params)
    local ok = nova.copy_path(params.source_path, params.destination_path)
    if ok then
      return string.format("Copied %s to %s", params.source_path, params.destination_path)
    end
    return string.format("Error: could not copy %s to %s", params.source_path, params.destination_path)
  end,
})

-- ── move_path ───────────────────────────────────────────────────────

nova.register_tool({
  name = "move_path",
  description = "Move (rename) a file or directory from source to destination. Works across directory boundaries. Prefer this over `bash mv` — it is sandboxed and cannot escape the project root.",
  parameters = {
    source_path = {
      type = "string",
      description = "Source path (relative to project root or absolute)",
    },
    destination_path = {
      type = "string",
      description = "Destination path (relative to project root or absolute)",
    },
  },
  handler = function(params)
    local ok = nova.move_path(params.source_path, params.destination_path)
    if ok then
      return string.format("Moved %s to %s", params.source_path, params.destination_path)
    end
    return string.format("Error: could not move %s to %s", params.source_path, params.destination_path)
  end,
})

-- ── delete_path ─────────────────────────────────────────────────────

nova.register_tool({
  name = "delete_path",
  description = "Delete a file or directory. By default only deletes a file or an empty directory; pass recursive=true to remove a directory with all its contents. Prefer this over `bash rm` — it is sandboxed and cannot escape the project root. Deletion is irreversible.",
  parameters = {
    path = {
      type = "string",
      description = "Path to delete (relative to project root or absolute)",
    },
    recursive = {
      type = "boolean",
      description = "Remove a directory and all its contents recursively (default false)",
      optional = true,
    },
  },
  handler = function(params)
    local opts = {}
    if params.recursive ~= nil then opts.recursive = params.recursive end
    local ok = nova.delete_path(params.path, opts)
    if ok then
      local note = params.recursive and " (recursive)" or ""
      return "Deleted" .. note .. ": " .. params.path
    end
    return "Error: could not delete " .. params.path
  end,
})
