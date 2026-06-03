# myprojects.nvim

A small Neovim project switcher built on top of
[fzf-lua](https://github.com/ibhagwan/fzf-lua).

`myprojects.nvim` is intentionally simple: give it a list of workspace folders
and explicit project folders, then open a fuzzy picker to switch Neovim's
current working directory.

## Features

- Scan configured workspace folders for projects.
- Add explicit project folders that should always appear.
- Search project folder names with `fzf-lua`.
- Display only folder names in the picker while keeping full paths available for
  preview and switching.
- Cancel switching when normal buffers have unsaved changes.
- Close loaded buffers before switching projects.
- Show a git status and recent commit preview for the selected project.

## Requirements

- Neovim 0.10 or newer.
- [fzf-lua](https://github.com/ibhagwan/fzf-lua).

## Installation

### lazy.nvim

```lua
{
  'shaunwen/myprojects.nvim',
  dependencies = { 'ibhagwan/fzf-lua' },
  cmd = 'MyProjects',
  keys = {
    { '<leader>pj', '<cmd>MyProjects<CR>', desc = 'Switch project' },
  },
  opts = {
    workspaces = {
      '~/workspace/projects',
      '~/workspace/worktrees',
    },
    projects = {
      '~/.config/nvim',
      '~/Documents/notes',
    },
  },
}
```

## Configuration

Default options:

```lua
require('myprojects').setup({
  workspaces = {},
  projects = {},
  project_depth = 1,
  close_open_buffers = true,
  command = 'MyProjects',
})
```

### `workspaces`

Type: `string[]`

Workspace directories to scan for project folders.

The scan is intentionally close to the old `fzf-project` workflow:

- direct child folders are listed as projects when they contain `.git`
- otherwise scanning continues until `project_depth` is reached

Example:

```lua
workspaces = {
  '~/workspace/projects',
  '~/workspace/projects/worktrees',
}
```

### `projects`

Type: `string[]`

Explicit project folders to always include.

Example:

```lua
projects = {
  '~/.config/nvim',
  '~/Documents/notes',
}
```

### `project_depth`

Type: `number`

Default: `1`

Maximum nested workspace scan depth.

With the default `1`, direct children of each workspace are included. If a child
folder contains `.git`, it is included immediately. If not, scanning continues
only until the configured depth.

### `close_open_buffers`

Type: `boolean`

Default: `true`

When enabled, normal loaded buffers are closed before switching to the selected project.

If any normal buffer has unsaved changes, switching is cancelled and a warning
lists the modified buffers. This prevents accidental loss of local edits.

### `command`

Type: `string`

Default: `'MyProjects'`

User command created by `setup`.

```vim
:MyProjects
```

## Usage

Run:

```vim
:MyProjects
```

Or map it:

```lua
vim.keymap.set('n', '<leader>pj', '<cmd>MyProjects<CR>', { desc = 'Switch project' })
```

The picker shows project folder names only. The full path is hidden from the
candidate list but used internally for the preview and switch action.

## Behavior

When a project is selected:

1. `myprojects.nvim` checks for modified normal buffers.
2. If modified buffers exist, it shows a warning and cancels the switch.
3. If switching is allowed, it closes normal loaded buffers when `close_open_buffers`
   is enabled.
4. It changes Neovim's current working directory with `:cd`.
5. It refreshes `lualine` when `lualine` is available.

## Duplicate Project Names

The picker displays only folder names. If two projects share the same folder
name, use the preview window to confirm the full path before selecting.

## License

MIT
