--!nonstrict
-- \\ EXPBUILD - by S.DOT // --

-- constants

local REQ_FUNC_CODE1 = [[_REQPOOL.require = function(module_name)
	local module = ]]
local REQ_FUNC_CODE2 = [[_REQPOOL[module_name]
	if not module then
		return error("No module "..tostring(module_name).." found, this is likely a bug!")
	end
	local fn = module[module_name]
	if fn then
		module[module_name] = nil
		module.ret = fn()
	end
	return module.ret
end]]
local BUILD_FORMATS = {
	"dense",
	"retain_lines",
	"readable",
}

local DEFAULT_INPUT_PATH = "src"
local DEFAULT_EXPBUILD_PREFIX = "__EXPBUILD"
local DEFAULT_EXPBUILD_STYLIZE = false
local DEFAULT_EXPBUILD_ENV_FIELD = "BUILDTYPE"
local DEFAULT_EXPBUILD_PROCESS_CONFIG_PATH = "./.darklua.json"

-- libraries

local argparse = require("@lunepkg/argparse")
local net = require("@lune/net")
local pathfs = require("@lunepkg/pathfs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local fs = pathfs.fs
local unzip = require("@luaupkg/unzip")

local ROOT_DIR = pathfs.Path.from(process.cwd)
local BUILD_DIR = ROOT_DIR:join("build")
local EXPBUILD_DIR = BUILD_DIR:join(".expbuild")
local TEMP_FILE = EXPBUILD_DIR:join("temp_file.luau")
local luauast = EXPBUILD_DIR:join("luau-ast.exe"):toString()
local darklua = EXPBUILD_DIR:join("darklua.exe"):toString()
local stylua = EXPBUILD_DIR:join("stylua.exe"):toString()

if not fs.isDir(BUILD_DIR) then fs.writeDir(BUILD_DIR) end
if not fs.isDir(EXPBUILD_DIR) then fs.writeDir(EXPBUILD_DIR) end

-- misc

local function randHash(str: string)
	local base64 = ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):split("")
	local hash = 2166136261
	local fnv_prime = 16777619

	for i = 1, str:len() do
		hash = (bit32.bxor(hash, string.byte(str, i))) * fnv_prime
		hash = hash % 4294967296
	end

	return table.concat({
		base64[bit32.extract(hash, 0, 8) % 64 + 1],
		base64[bit32.extract(hash, 8, 8) % 64 + 1],
		base64[bit32.extract(hash, 16, 8) % 64 + 1],
		base64[bit32.extract(hash, 24, 8) % 64 + 1],
	})
end

local function getFileInd(path: string)
	local base = (path:match("[\\/]?[^\\/]]*[\\/][^\\/]]+$") or "INVPATH"):gsub("\\", "/")

	return base .. "-" .. randHash(path)
end

-- dep downloads

local function downloadFromGithub(user: string, repo: string, file_name: string, release_id: number?): pathfs.File
	local repo_url = `https://api.github.com/repos/{user}/{repo}/releases/` .. (if release_id then tostring(release_id) else "latest")

	local request = net.request({
		url = repo_url,
		method = "GET",
	})
	assert(request.statusCode == 200, `failed to get releases\n{request.statusMessage}`)

	local body = serde.decode("json", request.body)
	local assets = body.assets :: { { name: string, browser_download_url: string } }
	local target = nil :: string?

	for _, asset in assets do
		if asset.name == file_name then
			target = asset.browser_download_url
			break
		end
	end
	assert(target, `no target {file_name} was fould`)

	local file_request = net.request({
		url = target,
		method = "GET",
		options = { decompress = false },
	})
	assert(file_request.statusCode == 200, `failed to download\n{file_request.statusMessage}`)

	local file_path = BUILD_DIR:join(file_name)
	pathfs.File.create(file_path, file_request.body, true)

	return pathfs.File.fromExisting(file_path)
end

-- analysis

type Analysis = {
	path: pathfs.Path,
	content: string,
	requires: { [string]: pathfs.Path },
	ast: { [any]: any },
	macro_flag: string?,
	hash: string,
}

local function astAnalyze(path: string): any
	local result = process.spawn(luauast, {
		path,
	}, {
		cwd = ROOT_DIR:toString(),
		stdio = "default",
	})
	assert(result.ok, `failed to analyze {path}\n{result.code}: {result.stdout}\n{result.stderr}`)

	return serde.decode("json", result.stdout)
end

local function fileProcess(input: string, output: string, build_type: string, config: string, env_field: string, format: string?)
	local result = process.spawn(darklua, {
		"process",
		input,
		output,
		"--config",
		config,
		format and "--format",
		format,
	}, {
		cwd = ROOT_DIR:toString(),
		env = { [env_field] = build_type },
		stdio = "default",
	})
	assert(result.ok, `failed to process {input}\n{result.code}: {result.stdout}\n{result.stderr}`)
end

local function fileStylize(input: string)
	local result = process.spawn(stylua, {
		input,
		"--verify",
		"--syntax",
		"Luau",
	}, {
		cwd = ROOT_DIR:toString(),
		stdio = "default",
	})
	assert(result.ok, `failed to stylize {input}\n{result.code}: {result.stdout}\n{result.stderr}`)
end

local function getRangeFromLinePos(line: string, content: string)
	assert(line:match("(%d+),(%d+) %- (%d+),(%d+)"), "invalid line")

	local line_poses = {}

	for capt in line:gmatch("%d+") do
		table.insert(line_poses, tonumber(capt))
	end
	assert(#line_poses == 4, "invalid line positions")

	local range_start = nil
	local range_end = nil

	local line_num = 0
	local row_num = 0

	for pos, char in utf8.codes(content) do
		if line_poses[1] == line_num and line_poses[2] == row_num then range_start = pos end
		if line_poses[3] == line_num and line_poses[4] == row_num then range_end = pos end

		if range_start and range_end then break end
		row_num += 1
		if utf8.char(char) == "\n" then
			line_num += 1
			row_num = 0
			continue
		end
	end

	return range_start, range_end
end

local function resolvePath(path_str: string | pathfs.Path, aliases: { [string]: pathfs.Path }?, root: pathfs.Path?, raw: boolean?): pathfs.Path
	local path = pathfs.Path.from(path_str)
	if aliases and path:toString():find("^@") then
		local target_alias, target_alias_path = nil, nil
		for alias, alias_path in aliases do
			if path:startsWith("@" .. alias) then
				target_alias, target_alias_path = alias, alias_path
				break
			end
		end
		assert(target_alias_path, `no alias for {path} was found`)
		path = target_alias_path:join(path:stripPrefix("@" .. target_alias))
	elseif path:startsWith("./") then
		path = (root or ROOT_DIR):join(path:stripPrefix("./") :: pathfs.Path)
	else
		path = (root or ROOT_DIR):join(path)
	end

	if raw then return pathfs.normalize(path) end

	local resolved = nil

	if fs.isFile(path) then
		resolved = path
	elseif fs.isFile(path:toString() .. ".luau") then
		resolved = pathfs.Path.from(path:toString() .. ".luau")
	elseif fs.isFile(path:toString() .. ".lua") then
		resolved = pathfs.Path.from(path:toString() .. ".lua")
	elseif fs.isDir(path) and fs.isFile(path:join("init")) then
		resolved = path:join("init")
	elseif fs.isDir(path) and fs.isFile(path:join("init.luau")) then
		resolved = path:join("init.luau")
	elseif fs.isDir(path) and fs.isFile(path:join("init.lua")) then
		resolved = path:join("init.lua")
	end

	assert(resolved, `failed to get full path for {path_str}`)
	return pathfs.normalize(resolved)
end

local function extractAstComments(analysis: any, content: string): { string }
	local comments = {}
	if analysis.commentLocations then
		for _, line in analysis.commentLocations do
			local pos1, pos2 = getRangeFromLinePos(line.location, content)
			local normalized = (utf8.char(utf8.codepoint(content, pos1, pos2))):gsub("\r", "")
			table.insert(comments, normalized)
		end
	end
	return comments
end

local function findConfigPath(path: pathfs.Path, root: pathfs.Path?): pathfs.Path?
	local dir_iter: pathfs.Directory = if fs.isDir(path) then pathfs.Directory.fromExisting(path) else pathfs.Directory.fromExisting(path:parent())

	while true do
		for _, child in dir_iter:readDir() do
			if child:fileStem() == ".luaurc" and fs.isFile(child) then return dir_iter.path:join(child) end
		end
		if not dir_iter.path:parent() then return end
		dir_iter = pathfs.Directory.fromExisting(dir_iter.path:parent())
	end
end

local function getConfigAliases(config_path: pathfs.Path): { [string]: pathfs.Path }
	local aliases = {}
	local config = serde.decode("json", fs.readFile(config_path))
	if config.aliases then
		for alias, path: string in config.aliases do
			if path:match("^~") then continue end
			aliases[alias] = resolvePath(path, nil, config_path:parent(), true)
		end
	end
	return aliases
end

local function extractAstRequires(analysis: any, path_buffer: { [string]: string }?): { [string]: string }
	path_buffer = path_buffer or {}
	for k, v in analysis do
		if typeof(v) == "table" then
			if
				v.type == "AstExprCall"
				and v.self == false
				and v.func
				and v.func.type == "AstExprGlobal"
				and v.func.global == "require"
				and v.args
				and #v.args == 1
				and v.args[1].type == "AstExprConstantString"
			then
				path_buffer[v.location] = v.args[1].value
				continue
			end
			extractAstRequires(v, path_buffer)
		end
	end
	return path_buffer :: { string }
end

local function fullAnalyze(path: pathfs.Path, processed_path: pathfs.Path?, root: pathfs.Path?)
	root = root or path:parent()

	local config = findConfigPath(path, root)
	local aliases = nil
	if config then aliases = getConfigAliases(config) end

	local content = fs.readFile((processed_path or path))
	local ast = astAnalyze((processed_path or path):toString())
	local comments = extractAstComments(ast, content)
	local raw_requires = extractAstRequires(ast)

	local macro = nil
	local requires = {}

	for _, str in comments do
		local matched = string.match(str, "^%-%-macro!([^\n%s]+)%s*$")
		if not macro then macro = matched end

		if macro then break end
	end

	for range, req_path in raw_requires do
		requires[range] = resolvePath(req_path, aliases, root)
	end

	local resolved_path = resolvePath(path, root)

	local analysis = {
		path = resolved_path,
		content = content,
		requires = requires,
		ast = ast,
		macro_flag = macro,
		hash = getFileInd(resolved_path:toString()),
	} :: Analysis

	return analysis
end

-- downloading aprograms :lol:
if not fs.isFile(luauast) then
	stdio.write(stdio.color("yellow") .. "luau-ast binary not found, downloading..." .. stdio.color("reset") .. "\n")
	local luau_zip = downloadFromGithub("luau-lang", "luau", "luau-windows.zip")
	stdio.write(stdio.color("green") .. "latest luau release downloaded" .. stdio.color("reset") .. "\n")

	local unzipped = unzip.load(buffer.fromstring(luau_zip:readFile()))
	local luau_ast_bin = unzipped:findEntry("/luau-ast.exe")
	assert(luau_ast_bin, "luau-ast binary not found in release")
	pathfs.File.create(luauast, unzipped:extract(luau_ast_bin, { type = "binary" }), true)
	luau_zip:removeFile()
end

if not fs.isFile(darklua) then
	stdio.write(stdio.color("yellow") .. "darklua binary not found, downloading..." .. stdio.color("reset") .. "\n")
	local darklua_zip = downloadFromGithub("seaofvoices", "darklua", "darklua-windows-x86_64.zip")
	stdio.write(stdio.color("green") .. "latest darklua release downloaded" .. stdio.color("reset") .. "\n")

	local unzipped = unzip.load(buffer.fromstring(darklua_zip:readFile()))
	local darklua_bin = unzipped:findEntry("/darklua.exe")
	assert(darklua_bin, "darklua binary not found in release")
	pathfs.File.create(darklua, unzipped:extract(darklua_bin, { type = "binary" }), true)
	darklua_zip:removeFile()
end

if not fs.isFile(stylua) then
	stdio.write(stdio.color("yellow") .. "stylua binary not found, downloading..." .. stdio.color("reset") .. "\n")
	local stylua_zip = downloadFromGithub("JohnnyMorganz", "stylua", "stylua-windows-x86_64.zip")
	stdio.write(stdio.color("green") .. "latest stylua release downloaded" .. stdio.color("reset") .. "\n")

	local unzipped = unzip.load(buffer.fromstring(stylua_zip:readFile()))
	local stylua_bin = unzipped:findEntry("/stylua.exe")
	assert(stylua_bin, "stylua binary not found in release")
	pathfs.File.create(stylua, unzipped:extract(stylua_bin, { type = "binary" }), true)
	stylua_zip:removeFile()
end

-- body

type ExpBuildConfig = {
	input_file: string?,
	build_type: string,
	format: string?,
	prefix: string?,
	stylize: boolean?,
	env_field: string?,
	process_config: string,
	postprocess_config: string?,
	postprocess_script: string?,
}

local function bundle(config: ExpBuildConfig)
	config.input_file = config.input_file or DEFAULT_INPUT_PATH
	config.build_type = config.build_type
	config.format = config.format
	config.prefix = config.prefix or DEFAULT_EXPBUILD_PREFIX
	config.stylize = config.stylize or DEFAULT_EXPBUILD_STYLIZE
	config.env_field = config.env_field or DEFAULT_EXPBUILD_ENV_FIELD
	config.process_config = config.process_config or DEFAULT_EXPBUILD_PROCESS_CONFIG_PATH
	config.postprocess_config = config.postprocess_config
	config.postprocess_script = config.postprocess_script

	local target = resolvePath(config.input_file):toString()

	local to_analyze = {} :: { string }
	local files = {} :: { [string]: Analysis }
	local analyzed = {} :: { string }

	table.insert(to_analyze, target)

	while #to_analyze > 0 do
		for idx, analyze_path in to_analyze do
			table.remove(to_analyze, idx)
			if table.find(analyzed, analyze_path) then continue end
			table.insert(analyzed, analyze_path)

			fileProcess(analyze_path, TEMP_FILE:toString(), config.build_type, config.process_config, config.env_field, config.format)

			local analysis = fullAnalyze(pathfs.Path.from(analyze_path), TEMP_FILE)
			files[analyze_path] = analysis

			for _, req in analysis.requires do
				table.insert(to_analyze, req:toString())
			end
		end
	end

	for _, analysis in files do
		local requires = {}
		local new_content = analysis.content:split("")

		for linepos, path in analysis.requires do
			local pos_start, pos_end = getRangeFromLinePos(linepos, analysis.content)
			local req_code = (`{config.prefix}_REQPOOL.require("{files[path:toString()].hash}")`):split("")
			table.insert(requires, {
				pos_start,
				pos_end,
				#req_code - (pos_end - pos_start),
				req_code,
			})
		end

		table.sort(requires, function(c1, c2)
			return c1[1] < c2[1]
		end)

		local global_diff = 0
		for _, info in requires do
			local pos_start, pos_end, diff, req_code = unpack(info)
			pos_start, pos_end = pos_start + global_diff, pos_end + global_diff

			for i = 1, #req_code do
				if pos_start + i - 1 >= pos_end then
					table.insert(new_content, pos_start + i - 1, req_code[i])
				else
					new_content[pos_start + i - 1] = req_code[i]
				end
			end

			if #req_code < (pos_end - pos_start) then
				for i = 1, pos_end - (pos_start + #req_code) do
					table.remove(new_content, pos_start + #req_code)
				end
			end

			global_diff += diff
		end

		analysis.content = table.concat(new_content)
	end

	local full_file = `local {config.prefix}_REQPOOL = \{}\n`

	for path, analysis in files do
		if path == target then continue end
		local data = `{config.prefix}_REQPOOL["{analysis.hash}"] = \{\n["{analysis.hash}"] = {analysis.macro_flag or ""}(function(...)\n`
		data ..= analysis.content .. ";\nend),\nret = nil :: any,\n}\n"
		full_file ..= data
	end

	full_file ..= `\n{config.prefix}` .. REQ_FUNC_CODE1 .. config.prefix .. REQ_FUNC_CODE2 .. "\n\n\n" .. files[target].content

	local output_path = BUILD_DIR:join(files[target].path:fileStem() .. "_bundled.luau")
	pathfs.File.create(output_path, full_file, true)

	if config.postprocess_config then
		fileProcess(output_path:toString(), output_path:toString(), config.build_type, config.postprocess_config, config.env_field, config.format)
	end

	if config.postprocess_script then
		local script_process = process.spawn("lune", {
			"run",
			config.postprocess_script,
			"--",
			output_path:toString(),
		}, {
			cwd = ROOT_DIR:toString(),
			stdio = "inherit",
		})
		if not script_process.ok then warn(`failed to run postprocess script, error code {script_process.code}\n{script_process.stderr}`) end
	end

	if config.stylize then fileStylize(output_path:toString()) end

	return output_path:toString()
end

local parser = argparse("ExpBuild", "Luau file bundler with support for macros")
parser:argument("input", "entrypoint for a bundle", "src/init.luau"):args(1)
parser:option("-t --type", "build type that will be passed to the global"):count(1):argname("<build_type>")
parser:flag("-s --stylize", "should the bundle be postprocessed with stylua"):count("0-1"):target("stylize")
parser:option("-f --format", "formatting style override for a bundle", "retain_lines"):count(1):argname(`<{table.concat(BUILD_FORMATS, " | ")}>`)

local args = parser:parse(process.args)

-- typechecking, yay

local input_path = args.input
assert(fs.isFile(input_path) or fs.isDir(input_path), "provided input path doesn't exist")

assert(fs.isFile("./.expbuild.toml"), "create '.expbuild.toml' in your root directory and configurate it before using expbuild!")
local expbuild_file = serde.decode("toml", fs.readFile("./.expbuild.toml"))
assert(expbuild_file, "failed to read expbuild config file")

local expbuild_file_configs = expbuild_file.buildtypes
assert(typeof(expbuild_file_configs) == "table", "add a 'buildtypes' hash map to the expbuild config and fill it with build types")

local build_type = args.type
assert(typeof(build_type) == "string", "invalid build type, check your command and expbuild config")

local expbuild_config = expbuild_file_configs[build_type]
assert(typeof(expbuild_config) == "table", "invalid build type, check your command and expbuild config")

-- config

local build_config = {
	input_file = input_path,
	build_type = build_type,
	format = args.format,
	prefix = expbuild_file.var_prefix,
	stylize = if expbuild_config.postprocess_stylua == nil then expbuild_config.postprocess_stylua else args.stylize,
	env_field = expbuild_file.env_field,
	process_config = if expbuild_config.process_config == nil then DEFAULT_EXPBUILD_PROCESS_CONFIG_PATH else expbuild_config.process_config,
	postprocess_config = expbuild_config.postprocess_config,
	postprocess_script = expbuild_config.postprocess_script,
}

-- more typechecking

assert(
	build_config.format == nil or table.find(BUILD_FORMATS, build_config.format),
	`invalid build format, \{{table.concat(BUILD_FORMATS, " | ")}\} or null expected`
)
assert(
	build_config.prefix == nil or (typeof(build_config.prefix) == "string" and (build_config.prefix:match("^[a-zA-Z_]?[a-zA-Z0-9_]*$") or ""):len() > 0),
	"invalid var_prefix, valid string or null expected"
)
assert(
	build_config.stylize == nil or typeof(build_config.stylize) == "boolean",
	"invalid postprocess_stylua value in expbuild config, boolean or null expected"
)
assert(build_config.env_field == nil or typeof(build_config.env_field) == "string", "invalid env_field value in expbuild config, string or null expected")
assert(typeof(build_config.process_config) == "string", "invalid env_field value in expbuild config, string or null expected")
assert(fs.isFile(build_config.process_config), "process config file doesn't exist")
assert(
	typeof(build_config.postprocess_config) == "string" or build_config.postprocess_config == nil,
	"invalid postprocess_config value in expbuild config, string or null expected"
)
assert(build_config.postprocess_config == nil or fs.isFile(build_config.postprocess_config), "postprocess config file doesn't exist")
assert(
	typeof(build_config.postprocess_script) == "string" or build_config.postprocess_script == nil,
	"invalid postprocess_script value in expbuild config, string or null expected"
)
assert(build_config.postprocess_script == nil or fs.isFile(build_config.postprocess_script), "postprocess script file doesn't exist")

-- entrypoint

local build_t = os.clock()
local output = bundle(build_config)
stdio.write(
	stdio.color("green")
		.. ("Successfully built file in %.3fms, output file: %s\n"):format((os.clock() - build_t) * 1000, output)
		.. stdio.color("reset")
		.. "\n"
)
