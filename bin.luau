local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local pathfs = require("@pkg/pathfs")
local fs = pathfs.fs
local unzip = require("@luaupkg/unzip")

local ROOT_DIR = pathfs.Path.from(process.cwd)
local BUILD_DIR = ROOT_DIR:join("build")
local luau_ast = BUILD_DIR:join("luau-ast.exe"):toString()

if not fs.isDir(BUILD_DIR:toString()) then
	fs.writeDir(ROOT_DIR:join("build"))
end

-- dep downloads

local function downloadFromGithub(user: string, repo: string, file_name: string, release_id: number?): pathfs.File
	local repo_url = `https://api.github.com/repos/{user}/{repo}/releases/`
		.. (if release_id then tostring(release_id) else "latest")

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

local function analyzeFile(path: string): any
	local result = process.spawn(luau_ast, {
		path,
	}, {
		cwd = ROOT_DIR:toString(),
		stdio = "default",
	})
	assert(result.ok, `failed to analyze {path}`)

	return serde.decode("json", result.stdout)
end

-- body

-- downloading ast generator :lol:
if not fs.isFile(luau_ast) then
	stdio.write(stdio.color("yellow") .. "luau-ast binary not found, downloading..." .. stdio.color("reset") .. "\n")
	local luau_zip = downloadFromGithub("luau-lang", "luau", "luau-windows.zip")
	stdio.write(stdio.color("green") .. "latest luau release downloaded" .. stdio.color("reset") .. "\n")

	local unzipped = unzip.load(buffer.fromstring(luau_zip:readFile()))
	local luau_ast_bin = unzipped:findEntry("/luau-ast.exe")
	assert(luau_ast_bin, "luau-ast binary not found in release")
	pathfs.File.create(BUILD_DIR:join(luau_ast_bin.name), unzipped:extract(luau_ast_bin, { type = "binary" }), true)
	fs.removeFile(luau_zip.path)
end

print(analyzeFile(ROOT_DIR:join("src/toanal.luau"):toString()))
