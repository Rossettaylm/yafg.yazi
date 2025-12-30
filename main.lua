local M = {
	editor = "hx",
	args = {},
	file_arg_format = "{file}:{row}:{col}",
}

local get_cwd = ya.sync(function()
	local active = cx.active
	if not active then
		return nil
	end
	local current = active.current
	if not current then
		return nil
	end
	-- 返回字符串而非 Url userdata，避免跨线程所有权转移问题
	return tostring(current.cwd)
end)

local sync_self = ya.sync(function()
	local self = {}
	for key, value in pairs(M) do
		if type(value) ~= "function" then
			self[key] = value
		end
	end
	return self
end)

function M:setup(opts)
	self.editor = opts.editor or self.editor
	self.args = opts.args or self.args
	self.file_arg_format = opts.file_arg_format or self.file_arg_format
end

function M:entry()
	ya.emit("escape", { visual = true })

	local _permit = ya.hide()
	local cwd_str = get_cwd()

	if not cwd_str then
		return ya.notify({ title = "Yafg", content = "Cannot get current directory", timeout = 5, level = "error" })
	end

	-- 将字符串转换回 Url 对象
	local cwd = Url(cwd_str)
	ya.dbg("Yafg", "cwd =", cwd_str)

	local output, err = M.run_with(cwd)
	if not output then
		return ya.notify({ title = "Yafg", content = tostring(err), timeout = 5, level = "error" })
	end

	local results = M.split_results(cwd, output)
	if #results == 0 then
		return
	elseif #results == 1 then
		local first_url = results[1][1]
		local cha = fs.cha(first_url)
		ya.emit(cha and cha.is_dir and "cd" or "reveal", { Url(first_url) })
	end

	local ss = sync_self()
	local args = {}
	for i, arg in ipairs(ss.args) do
		args[i] = ya.quote(arg)
	end
	local file_args = {}
	for i, result in ipairs(results) do
		local arg = string.gsub(ss.file_arg_format, "{file}", ya.quote(tostring(result[1])))
		arg = string.gsub(arg, "{row}", tostring(result[2]))
		arg = string.gsub(arg, "{col}", tostring(result[3]))
		file_args[i] = arg
	end

	local cmd = ss.editor .. " " .. table.concat(args, " ") .. " " .. table.concat(file_args, " ")
	ya.dbg("Yafg", "editor cmd", cmd)
	os.execute(cmd)
end

function M.run_with(cwd)
	ya.dbg("Yafg", "run_with cwd =", tostring(cwd))
	local target_dir = ya.quote(tostring(cwd))
	local cmd_args = string.format([=[
        export TARGET_DIR=%s
        export RG_PREFIX='rg --no-ignore --glob "!.git" --column --line-number --no-heading --color=always --smart-case'
        PREVIEW='bat --color=always --highlight-line={2} {1}'
        fzf --ansi --disabled --multi \
            --bind "start:reload:${RG_PREFIX} {q} ${TARGET_DIR}" \
            --bind "change:reload:sleep 0.1; ${RG_PREFIX} {q} ${TARGET_DIR} || true" \
            --bind "ctrl-t:transform:[[ ! \${FZF_PROMPT} =~ ripgrep ]] &&
                   echo 'rebind(change)+change-prompt(1. ripgrep> )+disable-search+reload:${RG_PREFIX} \{q} ${TARGET_DIR} || true' ||
                   echo 'unbind(change)+change-prompt(2. fzf> )+enable-search+reload:${RG_PREFIX} \"\" ${TARGET_DIR} || true'" \
            --color "hl:-1:underline,hl+:-1:underline:reverse" \
            --prompt '1. ripgrep> ' \
            --delimiter : \
            --header 'CTRL-T: Switch between ripgrep/fzf' \
            --preview "${PREVIEW}" \
            --preview-window 'up,60%%,~3,+{2}+3/2' \
            --nth '3..'
	]=], target_dir)
	ya.dbg("Yafg", "cmd_args =", cmd_args)
	local child, err =
		Command("bash"):arg({ "-c", cmd_args }):stdin(Command.INHERIT):stdout(Command.PIPED):stderr(Command.PIPED):spawn()

	if not child then
		return nil, Err("Failed to start `fzf`, error: %s", err)
	end

	local output, err = child:wait_with_output()
	if not output then
		return nil, Err("Cannot read `fzf` output, error: %s", err)
	end

	ya.dbg("Yafg", "fzf exit code =", output.status.code)
	ya.dbg("Yafg", "fzf stdout =", output.stdout)
	ya.dbg("Yafg", "fzf stderr =", output.stderr)

	if not output.status.success and output.status.code ~= 130 then
		return nil, Err("`fzf` exited with error code %s, stderr: %s", output.status.code, output.stderr)
	end
	return output.stdout, nil
end

function M.split_results(cwd, output)
	local t = {}
	for line in output:gmatch("[^\r\n]+") do
		local file, row, col = (string.gmatch(line, "(..-):(%d+):(%d+):"))()
		local u = Url(file)
		if u.is_absolute then
			t[#t + 1] = { u, row, col }
		else
			t[#t + 1] = { cwd:join(u), row, col }
		end
	end
	return t
end

return M
