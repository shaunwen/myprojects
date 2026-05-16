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

local function ensure_valid_process_cwd()
  local cwd = vim.uv.cwd()
  if cwd and is_dir(cwd) then
    return cwd
  end

  local fallback = normalize('~')
  if not is_dir(fallback) then
    return nil
  end

  pcall(vim.uv.chdir, fallback)
  pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(fallback))
  return fallback
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

local function project_name(path)
  return vim.fn.fnamemodify(path, ':t')
end

local function project_display_path(path)
  return vim.fn.fnamemodify(path, ':~')
end

local function git_branch(path)
  local branch = vim
    .system({ 'git', '-C', path, 'branch', '--show-current' }, { text = true })
    :wait()

  if branch.code == 0 and branch.stdout and vim.trim(branch.stdout) ~= '' then
    return vim.trim(branch.stdout)
  end

  local commit = vim
    .system({ 'git', '-C', path, 'rev-parse', '--short', 'HEAD' }, { text = true })
    :wait()

  if commit.code == 0 and commit.stdout and vim.trim(commit.stdout) ~= '' then
    return vim.trim(commit.stdout)
  end

  return ''
end

local function build_project_entries(projects)
  local name_counts = {}
  for _, project in ipairs(projects) do
    local name = project_name(project)
    name_counts[name] = (name_counts[name] or 0) + 1
  end

  local entries = {}
  local by_entry = {}
  for _, project in ipairs(projects) do
    local name = project_name(project)
    local entry = name
    if name_counts[name] > 1 then
      entry = string.format('%s  %s', name, project_display_path(project))
    end

    table.insert(entries, entry)
    by_entry[entry] = project
  end

  return entries, by_entry
end

local function project_path_from_line(line, project_by_entry)
  if not line or line == '' then
    return nil
  end

  if project_by_entry[line] then
    return project_by_entry[line]
  end

  local raw_path, name = line:match('^([^\t]+)\t(.+)$')
  if raw_path and is_dir(raw_path) then
    return raw_path
  end

  if name and project_by_entry[name] then
    return project_by_entry[name]
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

    local current_project = vim.fn.getcwd()
    vim.g.myprojects_current_project = current_project
    vim.g.myprojects_current_branch = git_branch(current_project)
    vim.api.nvim_exec_autocmds('User', {
      pattern = 'MyProjectsChanged',
      data = {
        path = current_project,
        branch = vim.g.myprojects_current_branch,
      },
    })

    local ok, lualine = pcall(require, 'lualine')
    if ok then
      lualine.refresh()
    end

    vim.notify('Switched project to ' .. path, vim.log.levels.INFO)
  end)
end

function M.switch_project()
  local fzf = require('fzf-lua')
  local picker_cwd = ensure_valid_process_cwd()
  if not picker_cwd then
    vim.notify('Unable to open project picker: current directory is invalid', vim.log.levels.ERROR)
    return
  end

  local projects = collect_projects()

  if #projects == 0 then
    vim.notify('No projects found', vim.log.levels.WARN)
    return
  end

  local entries, project_by_entry = build_project_entries(projects)

  fzf.fzf_exec(entries, {
    prompt = 'Projects> ',
    cwd = picker_cwd,
    fzf_opts = {
      ['--no-multi'] = true,
    },
    preview = function(args)
      local cwd = project_path_from_line(args[1], project_by_entry)
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

      local branch = git_branch(cwd)
      local parts = {
        'Project: ' .. project_name(cwd),
        'Path: ' .. project_display_path(cwd),
        'Branch: ' .. (branch ~= '' and branch or '-'),
        '',
      }
      if status.stdout and status.stdout ~= '' then
        table.insert(parts, 'Status:')
        table.insert(parts, status.stdout)
      end
      if log.stdout and log.stdout ~= '' then
        table.insert(parts, '')
        table.insert(parts, 'Recent commits:')
        table.insert(parts, log.stdout)
      end

      return table.concat(parts, '\n')
    end,
    actions = {
      ['default'] = function(selected)
        local path = project_path_from_line(selected[1], project_by_entry)
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
