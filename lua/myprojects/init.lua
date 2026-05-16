local M = {}

local defaults = {
  workspaces = {},
  projects = {},
  project_depth = 1,
  close_open_buffers = true,
  command = 'MyProjects',
}

local config = vim.deepcopy(defaults)

local function normalize(path)
  return vim.fs.normalize(vim.fn.expand(path))
end

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

local function has_git_dir(path)
  return vim.uv.fs_stat(path .. '/.git') ~= nil
end

local function child_dirs(path)
  local dirs = {}
  local scanner = vim.uv.fs_scandir(path)

  if not scanner then
    return dirs
  end

  while true do
    local name, kind = vim.uv.fs_scandir_next(scanner)
    if not name then
      break
    end

    if kind == 'directory' and not vim.startswith(name, '.') then
      table.insert(dirs, path .. '/' .. name)
    end
  end

  table.sort(dirs)
  return dirs
end

local function scan_workspace(path, depth, projects)
  for _, dir in ipairs(child_dirs(path)) do
    if has_git_dir(dir) or depth >= config.project_depth then
      table.insert(projects, dir)
    else
      scan_workspace(dir, depth + 1, projects)
    end
  end
end

local function collect_projects()
  local seen = {}
  local projects = {}

  local function add(path)
    local normalized = normalize(path)
    if is_dir(normalized) and not seen[normalized] then
      seen[normalized] = true
      table.insert(projects, normalized)
    end
  end

  for _, workspace in ipairs(config.workspaces) do
    local normalized = normalize(workspace)
    if is_dir(normalized) then
      local found = {}
      scan_workspace(normalized, 1, found)
      for _, project in ipairs(found) do
        add(project)
      end
    end
  end

  for _, project in ipairs(config.projects) do
    add(project)
  end

  table.sort(projects, function(a, b)
    local name_a = vim.fn.fnamemodify(a, ':t')
    local name_b = vim.fn.fnamemodify(b, ':t')
    if name_a == name_b then
      return a < b
    end
    return name_a < name_b
  end)

  return projects
end

local function modified_buffers()
  local modified = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.bo[bufnr].buftype == '' and vim.bo[bufnr].modified then
        local name = vim.api.nvim_buf_get_name(bufnr)
        table.insert(modified, name ~= '' and vim.fn.fnamemodify(name, ':~:.') or '[No Name]')
      end
    end
  end

  return modified
end

local function close_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

local function entry_for(path)
  return vim.fn.fnamemodify(path, ':t')
end

local function build_project_lookup(projects)
  local by_name = {}

  for _, project in ipairs(projects) do
    local name = vim.fn.fnamemodify(project, ':t')
    by_name[name] = by_name[name] or project
  end

  return by_name
end

local function project_path_from_line(line, project_by_name)
  if not line or line == '' then
    return nil
  end

  local raw_path, name = line:match('^([^\t]+)\t(.+)$')
  if raw_path and is_dir(raw_path) then
    return raw_path
  end

  if name and project_by_name[name] then
    return project_by_name[name]
  end

  if project_by_name[line] then
    return project_by_name[line]
  end

  if is_dir(line) then
    return normalize(line)
  end

  return nil
end

local function switch_to_project(path)
  vim.schedule(function()
    local modified = modified_buffers()
    if #modified > 0 then
      vim.notify(
        'Save or close modified buffers before switching projects:\n'
          .. table.concat(modified, '\n'),
        vim.log.levels.WARN
      )
      return
    end

    if config.close_open_buffers then
      close_buffers()
    end

    vim.cmd('cd ' .. vim.fn.fnameescape(path))

    local ok, lualine = pcall(require, 'lualine')
    if ok then
      lualine.refresh()
    end

    vim.notify('Switched project to ' .. path, vim.log.levels.INFO)
  end)
end

function M.switch_project()
  local fzf = require('fzf-lua')
  local projects = collect_projects()

  if #projects == 0 then
    vim.notify('No projects found', vim.log.levels.WARN)
    return
  end

  local entries = vim.tbl_map(function(project)
    return entry_for(project)
  end, projects)
  local project_by_name = build_project_lookup(projects)

  fzf.fzf_exec(entries, {
    prompt = 'Projects> ',
    fzf_opts = {
      ['--no-multi'] = true,
    },
    preview = function(args)
      local cwd = project_path_from_line(args[1], project_by_name)
      if not cwd then
        return 'No project selected'
      end

      local status = vim
        .system({ 'git', '-C', cwd, '-c', 'color.status=always', 'status', '-s' }, { text = true })
        :wait()
      local log = vim
        .system({
          'git',
          '-C',
          cwd,
          'log',
          '--color',
          '--pretty=format:%C(yellow)%h%Creset %Cgreen(%cr)%Creset %s %C(blue)<%an>%Creset',
          '-n',
          '30',
        }, { text = true })
        :wait()

      local parts = {}
      if status.stdout and status.stdout ~= '' then
        table.insert(parts, status.stdout)
      end
      if log.stdout and log.stdout ~= '' then
        if #parts > 0 then
          table.insert(parts, '')
        end
        table.insert(parts, log.stdout)
      end

      return #parts > 0 and table.concat(parts, '\n') or cwd
    end,
    actions = {
      ['default'] = function(selected)
        local path = project_path_from_line(selected[1], project_by_name)
        if path then
          switch_to_project(path)
        else
          vim.notify('Unable to resolve selected project', vim.log.levels.WARN)
        end
      end,
    },
  })
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command(config.command, function()
    M.switch_project()
  end, { force = true })
end

return M
