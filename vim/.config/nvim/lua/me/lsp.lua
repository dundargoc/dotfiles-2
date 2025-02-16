local lsp = require 'vim.lsp'
local api = vim.api
local ms = lsp.protocol.Methods
local M = {}

---@diagnostic disable-next-line: deprecated
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients


function M.mk_config(config)
  local lsp_compl = require('lsp_compl')
  local capabilities = vim.tbl_deep_extend(
    "force",
    lsp.protocol.make_client_capabilities(),
    lsp_compl.capabilities(),
    {
      workspace = {
        didChangeWatchedFiles = {
          dynamicRegistration = true
        }
      }
    }
  )
  local defaults = {
    flags = {
      debounce_text_changes = 80,
    },
    handlers = {},
    capabilities = capabilities,
    on_attach = function(client, bufnr)
      local triggers = vim.tbl_get(client.server_capabilities, "completionProvider", "triggerCharacters")
      triggers = triggers or {"."}
      if triggers then
        for _, char in ipairs({"a", "e", "i", "o", "u"}) do
          if not vim.tbl_contains(triggers, char) then
            table.insert(triggers, char)
          end
        end
      end
      lsp_compl.attach(client, bufnr)
    end,
    init_options = vim.empty_dict(),
    settings = vim.empty_dict(),
  }
  if config then
    return vim.tbl_deep_extend("force", defaults, config)
  else
    return defaults
  end
end

function M.find_root(markers, path)
  path = path or api.nvim_buf_get_name(0)
  local match = vim.fs.find(markers, { path = path, upward = true })[1]
  if match then
    local stat = vim.loop.fs_stat(match)
    if stat and stat.type == "directory" then
      return vim.fn.fnamemodify(match, ':p:h:h')
    end
    return vim.fn.fnamemodify(match, ':p:h')
  end
  return nil
end


function M.setup()
  vim.lsp.handlers['textDocument/hover'] = vim.lsp.with(vim.lsp.handlers.hover, { border = 'single' })
  vim.lsp.handlers['textDocument/signatureHelp'] = vim.lsp.with(vim.lsp.handlers.signature_help, { border = 'single' })
  local servers = {
    {'html', {'vscode-html-language-server', '--stdio'}},
    {'htmldjango', {'vscode-html-language-server', '--stdio'}},
    {'json', {'vscode-json-language-server', '--stdio'}},
    {'css', {'vscode-css-language-server', '--stdio'}},
    {'c', 'clangd', {'.git'}},
    {'sh', {'bash-language-server', 'start'}},
    {'rust', 'rust-analyzer', {'Cargo.toml', '.git'}},
    {'tex', 'texlab', {'.git'}},
    {'zig', 'zls', {'build.zig', '.git'}},
    {'javascript', {'typescript-language-server', '--stdio'}, {"package.json", ".git"}},
    {'typescript', {'typescript-language-server', '--stdio'}, {"package.json", ".git"}},
  }
  local lsp_group = api.nvim_create_augroup('lsp', {})
  for _, server in pairs(servers) do
    api.nvim_create_autocmd('FileType', {
      pattern = server[1],
      group = lsp_group,
      callback = function(args)
        local cmd = server[2]
        local config = M.mk_config({
          name = type(cmd) == "table" and cmd[1] or cmd,
          cmd = type(cmd) == "table" and cmd or {cmd},
        })
        local markers = server[3]
        if markers then
          config.root_dir = M.find_root(markers, args.file)
        end
        vim.lsp.start(config)
      end,
    })
  end
  if vim.fn.exists('##LspAttach') ~= 1 then
    return
  end
  local keymap = vim.keymap
  if vim.fn.exists("##LspProgress") == 1 then
    api.nvim_create_autocmd("LspProgress", {
      group = lsp_group,
      command = "redrawstatus"
    })
  end
  api.nvim_create_autocmd('LspAttach', {
    group = lsp_group,
    callback = function(args)
      -- array of mappings to setup; {<capability>, <mode>, <lhs>, <rhs>}
      local key_mappings = {
        {"referencesProvider", "n", "gr", vim.lsp.buf.references},
        {"implementationProvider", "n", "gD",  vim.lsp.buf.implementation},
        {"signatureHelpProvider", "i", "<c-space>", vim.lsp.buf.signature_help},
        {"workspaceSymbolProvider", "n", "gW", vim.lsp.buf.workspace_symbol},
        {"codeLensProvider", "n", "<leader>cr", vim.lsp.codelens.refresh},
        {"codeLensProvider", "n", "<leader>ce", vim.lsp.codelens.run},
        {"codeLensProvider", "n", "<leader>ca",
          function()
            vim.lsp.codelens.refresh()
            local bufnr = api.nvim_get_current_buf()
            api.nvim_create_autocmd({'InsertLeave', 'CursorHold'}, {
              group = api.nvim_create_augroup(string.format('lsp-codelens-%s', bufnr), {}),
              buffer = bufnr,
              callback = function()
                vim.lsp.codelens.refresh()
              end,
            })
          end
        },
        {"codeLensProvider", "n", "<leader>cc",
          function()
            local bufnr = api.nvim_get_current_buf()
            if vim.lsp.codelens.clear then
              vim.lsp.codelens.clear(nil, bufnr)
            end
            local group = string.format('lsp-codelens-%s', bufnr)
            pcall(api.nvim_del_augroup_by_name, group)
          end
        },
      }

      keymap.set({"n", "v"}, "<a-CR>", vim.lsp.buf.code_action, { buffer = args.buf })
      keymap.set("n", "<leader>r", "<Cmd>lua vim.lsp.buf.code_action { context = { only = {'refactor'} }}<CR>", { buffer = args.buf })
      keymap.set("v", "<leader>r", "<Cmd>lua vim.lsp.buf.code_action { context = { only = {'refactor'}}}<CR>", { buffer = args.buf })

      local client = assert(vim.lsp.get_client_by_id(args.data.client_id))
      keymap.set("n", "crr", "<Cmd>lua vim.lsp.buf.rename(vim.fn.input('New Name: '))<CR>", { buffer = args.buf })
      keymap.set("i", "<c-n>", function()
        require("lsp_compl").trigger_completion()
      end, { buffer = args.buffer })
      keymap.set('i', '<CR>', function()
        return require('lsp_compl').accept_pum() and '<c-y>' or '<CR>'
      end, { expr = true, buffer = args.buffer })

      for _, mappings in pairs(key_mappings) do
        local capability, mode, lhs, rhs = unpack(mappings)
        if client.server_capabilities[capability] then
          keymap.set(mode, lhs, rhs, { buffer = args.buf, silent = true })
        end
      end
      if client.server_capabilities.documentHighlightProvider then
        local group = api.nvim_create_augroup(string.format('lsp-%s-%s', args.buf, args.data.client_id), {})
        api.nvim_create_autocmd({'CursorHold', 'CursorHoldI'}, {
          group = group,
          buffer = args.buf,
          callback = function()
            local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
            client.request('textDocument/documentHighlight', params, nil, args.buf)
          end,
        })
        api.nvim_create_autocmd('CursorMoved', {
          group = group,
          buffer = args.buf,
          callback = function()
            pcall(vim.lsp.buf.clear_references)
          end,
        })
      end
    end,
  })
  api.nvim_create_autocmd('LspDetach', {
    group = lsp_group,
    callback = function(args)
      local group = api.nvim_create_augroup(string.format('lsp-%s-%s', args.buf, args.data.client_id), {})
      pcall(api.nvim_del_augroup_by_name, group)
      pcall(require('lsp_compl').detach, args.data.client_id, args.buf)
    end,
  })

  api.nvim_create_user_command(
    'LspStop',
    function(kwargs)
      local name = kwargs.fargs[1]
      for _, client in ipairs(get_clients({ name = name })) do
        client.stop()
      end
    end,
    {
      nargs = 1,
      complete = function()
        return vim.tbl_map(function(c) return c.name end, get_clients())
      end
    }
  )
  api.nvim_create_user_command(
    "LspRestart",
    function(kwargs)
      local name = kwargs.fargs[1]
      for _, client in ipairs(get_clients({ name = name })) do
        local bufs = lsp.get_buffers_by_client_id(client.id)
        client.stop()
        vim.wait(30000, function()
          return lsp.get_client_by_id(client.id) == nil
        end)
        local client_id = lsp.start_client(client.config)
        if client_id then
          for _, buf in ipairs(bufs) do
            lsp.buf_attach_client(buf, client_id)
          end
        end
      end
    end,
    {
      nargs = 1,
      complete = function()
        return vim.tbl_map(function(c) return c.name end, get_clients())
      end
    }
  )
end

local function mk_tag_item(name, range, uri)
  local start = range.start
  return {
    name = name,
    filename = vim.uri_to_fname(uri),
    cmd = string.format(
      'call cursor(%d, %d)', start.line + 1, start.character + 1
    )
  }
end

function M.symbol_tagfunc(pattern, flags)
  if not (flags == 'c' or flags == '' or flags == 'i') then
    return vim.NIL
  end
  local clients = get_clients({ method = ms.workspace_symbol })
  local num_clients = vim.tbl_count(clients)
  local results = {}
  local bufnr = api.nvim_get_current_buf()
  for _, client in pairs(clients) do
    client.request(ms.workspace_symbol, { query = pattern }, function(_, method_or_result, result_or_ctx)
      local result = type(method_or_result) == 'string' and result_or_ctx or method_or_result
      for _, symbol in pairs(result or {}) do
        local loc = symbol.location
        local item = mk_tag_item(symbol.name, loc.range, loc.uri)
        item.kind = (lsp.protocol.SymbolKind[symbol.kind] or 'Unknown')[1]
        table.insert(results, item)
      end
      num_clients = num_clients - 1
    end, bufnr)
  end
  vim.wait(1500, function() return num_clients == 0 end)
  return results
end


return M
