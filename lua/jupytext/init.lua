local commands = require "jupytext.commands"
local utils = require "jupytext.utils"

local M = {}

M.config = {
  style = "hydrogen",
  output_extension = "auto",
  force_ft = nil,
  custom_language_formatting = {},
}

local write_to_ipynb = function(event, output_extension)
  local ipynb_filename = event.match
  local jupytext_filename = utils.get_jupytext_file(ipynb_filename, output_extension)
  jupytext_filename = vim.fn.resolve(vim.fn.expand(jupytext_filename))

  vim.cmd.write({ jupytext_filename, bang = true })
  commands.run_jupytext_command(vim.fn.shellescape(jupytext_filename), {
    ["--update"] = "",
    ["--to"] = "ipynb",
    ["--output"] = vim.fn.shellescape(ipynb_filename),
  })
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_option_value("modified", false, { buf = buf })

  local post_write = "BufWritePost"
  if event.event == "FileWriteCmd" then
    post_write = "FileWritePost"
  end
  vim.api.nvim_exec_autocmds(post_write, { pattern = ipynb_filename })
end

local style_and_extension = function(metadata)
  local to_extension_and_style
  local output_extension

  local custom_formatting = nil
  if utils.check_key(M.config.custom_language_formatting, metadata.language) then
    custom_formatting = M.config.custom_language_formatting[metadata.language]
  end

  if custom_formatting then
    output_extension = custom_formatting.extension
    to_extension_and_style = output_extension .. ":" .. custom_formatting.style
  else
    if M.config.output_extension == "auto" then
      output_extension = metadata.extension
    else
      output_extension = M.config.output_extension
    end
    to_extension_and_style = M.config.output_extension .. ":" .. M.config.style
  end

  return custom_formatting, output_extension, to_extension_and_style
end

local cleanup = function(ipynb_filename, delete)
  local metadata = utils.get_ipynb_metadata(ipynb_filename)

  local _, output_extension, _ = style_and_extension(metadata)

  local jupytext_filename = utils.get_jupytext_file(ipynb_filename, output_extension)
  if delete then
    vim.fn.delete(vim.fn.resolve(vim.fn.expand(jupytext_filename)))
  end
end

local read_from_ipynb = function(ev)
  local metadata = utils.get_ipynb_metadata(ev.match)
  local ipynb_filename = vim.fn.resolve(vim.fn.expand(ev.match))
  local buf = ev.buf

  -- Decide output extension and style
  local custom_formatting, output_extension, to_extension_and_style = style_and_extension(metadata)

  local jupytext_filename = utils.get_jupytext_file(ipynb_filename, output_extension)
  local jupytext_file_exists = vim.fn.filereadable(jupytext_filename) == 1
  -- filename is the notebook
  local filename_exists = vim.fn.filereadable(ipynb_filename)

  if filename_exists and not jupytext_file_exists then
    commands.run_jupytext_command(vim.fn.shellescape(ipynb_filename), {
      ["--to"] = to_extension_and_style,
      ["--output"] = vim.fn.shellescape(jupytext_filename),
    })
  end

  -- This is when the magic happens and we read the new file into the buffer
  if vim.fn.filereadable(jupytext_filename) then
    local jupytext_content = vim.fn.readfile(jupytext_filename)

    -- Replace the buffer content with the jupytext content
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, jupytext_content)
  else
    error "Couldn't find jupytext file."
    return
  end

  -- If jupytext version already existed then don't delete otherwise consider
  -- it to be sort of a temp file.
  local should_delete = not jupytext_file_exists
  vim.api.nvim_create_autocmd("BufUnload", {
    pattern = "<buffer>",
    group = "jupytext-nvim",
    callback = function(ev)
      cleanup(ev.match, should_delete)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd" }, {
    pattern = "<buffer>",
    group = "jupytext-nvim",
    callback = function(ev)
      write_to_ipynb(ev, output_extension)
    end,
  })

  local ft = M.config.force_ft

  if custom_formatting ~= nil then
    if custom_formatting.force_ft then
      if custom_formatting.style == "quarto" then
        ft = "quarto"
      else
        -- just let the user set whatever ft they want
        ft = custom_formatting.force_ft
      end
    end
  end

  if not ft then
    ft = metadata.language
  end

  vim.api.nvim_set_option_value("fenc", "utf-8", { buf = buf })
  vim.api.nvim_set_option_value("ft", ft, { buf = buf })
  vim.api.nvim_set_option_value("modified", false, { buf = buf })

  -- First time we enter the buffer redraw. Don't know why but jupytext.vim was
  -- doing it. Apply Chesterton's fence principle.
  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = "<buffer>",
    group = "jupytext-nvim",
    once = true,
    command = "redraw",
  })
end

M.setup = function(config)
  vim.validate({ config = { config, "table", true } })
  M.config = vim.tbl_deep_extend("force", M.config, config or {})

  vim.validate({
    style = { M.config.style, "string" },
    output_extension = { M.config.output_extension, "string" },
  })

  vim.api.nvim_create_augroup("jupytext-nvim", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = { "*.ipynb" },
    group = "jupytext-nvim",
    callback = function(ev)
      read_from_ipynb(ev)
    end,
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    pattern = { "*.ipynb" },
    group = "jupytext-nvim",
    callback = function(ev)
      if vim.api.nvim_get_vvar "vim_did_enter" == 1 then
        read_from_ipynb(ev)
      end
    end,
  })

  -- If we are using LazyVim make sure to run the LazyFile event so that the LSP
  -- and other important plugins get going
  if pcall(require, "lazy") then
    vim.api.nvim_exec_autocmds("User", { pattern = "LazyFile", modeline = false })
  end
end

return M
