local luacheck = require "luacheck"
local argparse = require "luacheck.argparse"
local stds = require "luacheck.stds"
local options = require "luacheck.options"
local expand_rockspec = require "luacheck.expand_rockspec"
local multithreading = require "luacheck.multithreading"
local cache = require "luacheck.cache"
local format = require "luacheck.format"
local version = require "luacheck.version"
local fs = require "luacheck.fs"
local utils = require "luacheck.utils"

local function fatal(msg)
   io.stderr:write("Fatal error: "..msg.."\n")
   os.exit(3)
end

local function global_error_handler(err)
   if type(err) == "table" and err.pattern then
      fatal("Invalid pattern '" .. err.pattern .. "'")
   else
      fatal(debug.traceback(
         ("Luacheck %s bug (please report at github.com/mpeterv/luacheck/issues):\n%s"):format(luacheck._VERSION, err), 2))
   end
end

local function main()
   local default_config = ".luacheckrc"
   local default_cache_path = ".luacheckcache"

   local function get_parser()
      local parser = argparse("luacheck", "luacheck " .. luacheck._VERSION .. ", a simple static analyzer for Lua.", [[
Links:

   Luacheck on GitHub: https://github.com/mpeterv/luacheck
   Luacheck documentation: http://luacheck.readthedocs.org]])

      parser:argument "files"
         :description (fs.has_lfs and [[List of files, directories and rockspecs to check.
Pass "-" to check stdin.]] or [[List of files and rockspecs to check.
Pass "-" to check stdin.]])
         :args "+"
         :argname "<file>"

      parser:flag("-g --no-global", [[Filter out warnings related to global variables.
Equivalent to --ignore 1.]])
      parser:flag("-u --no-unused", [[Filter out warnings related to unused variables and values.
Equivalent to --ignore [23].]])
      parser:flag("-r --no-redefined", [[Filter out warnings related to redefined variables.
Equivalent to --ignore 4.]])

      parser:flag("-a --no-unused-args", [[Filter out warnings related to unused arguments and loop variables.
Equivalent to --ignore 21[23].]])
      parser:flag("-s --no-unused-secondaries",
         "Filter out warnings related to unused variables set together with used ones.")
      parser:flag("--no-self",
         "Filter out warnings related to implicit self argument.")

      parser:option("--std", [[Set standard globals. <std> must be one of:
   _G - globals of the current Lua interpreter (default);
   lua51 - globals of Lua 5.1;
   lua52 - globals of Lua 5.2;
   lua52c - globals of Lua 5.2 compiled with LUA_COMPAT_ALL;
   lua53 - globals of Lua 5.3;
   lua53c - globals of Lua 5.3 compiled with LUA_COMPAT_5_2;
   luajit - globals of LuaJIT 2.0;
   min - intersection of globals of Lua 5.1, Lua 5.2, Lua 5.3 and LuaJIT 2.0;
   max - union of globals of Lua 5.1, Lua 5.2, Lua 5.3 and LuaJIT 2.0;
   none - no standard globals.]])
      parser:option("--globals", "Add custom globals on top of standard ones.")
         :args "*"
         :count "*"
         :argname "<global>"
      parser:option("--read-globals", "Add read-only globals.")
         :args "*"
         :count "*"
         :argname "<global>"
      parser:option("--new-globals", "Set custom globals. Removes custom globals added previously.")
         :args "*"
         :count "*"
         :argname "<global>"
      parser:option("--new-read-globals", "Set read-only globals. Removes read-only globals added previously.")
         :args "*"
         :count "*"
         :argname "<global>"
      parser:flag("-c --compat", "Equivalent to --std max.")
      parser:flag("-d --allow-defined", "Allow defining globals implicitly by setting them.")
      parser:flag("-t --allow-defined-top", "Allow defining globals implicitly by setting them in the top level scope.")
      parser:flag("-m --module", "Limit visibility of implicitly defined globals to their files.")

      parser:option("--ignore -i", [[Filter out warnings matching these patterns.
If a pattern contains slash, part before slash matches warning code
   and part after it matches name of related variable.
Otherwise, if the pattern contains letters or underscore,
   it matches name of related variable.
Otherwise, the pattern matches warning code.]])
         :args "+"
         :count "*"
         :argname "<patt>"
      parser:option("--enable -e", "Do not filter out warnings matching these patterns.")
         :args "+"
         :count "*"
         :argname "<patt>"
      parser:option("--only -o", "Filter out warnings not matching these patterns.")
         :args "+"
         :count "*"
         :argname "<patt>"

      parser:flag("--no-inline", "Disable inline options.")

      parser:mutex(
         parser:option("--config", "Path to configuration file. (default: "..default_config..")"),
         parser:flag("--no-config", "Do not look up configuration file.")
      )

      if fs.has_lfs then
         parser:mutex(
            parser:option("--cache", "Path to cache file.", default_cache_path)
               :defmode "arg",
            parser:flag("--no-cache", "Do not use cache.")
         )
      end

      if multithreading.has_lanes then
         parser:option("-j --jobs", "Check <jobs> files in parallel.")
            :convert(tonumber)
      end

      parser:option("--formatter" , [[Use custom formatter. <formatter> must be a module name or one of:
   TAP - Test Anything Protocol formatter;
   JUnit - JUnit XML formatter;
   plain - simple warning-per-line formatter;
   default - standard formatter.]])

      parser:flag("-q --quiet", [[Suppress output for files without warnings.
   -qq: Suppress output of warnings.
   -qqq: Only print total number of warnings and errors.]])
         :count "0-3"

      parser:flag("--codes", "Show warning codes.")

      parser:flag("--no-color", "Do not color output.")

      parser:flag("-v --version", "Show version info and exit.")
         :action(function() print(version.string) os.exit(0) end)

      return parser
   end

   -- Expands folders, rockspecs, -
   -- Returns new array of filenames and table mapping indexes of bad rockspecs to error messages. 
   -- Removes "./" in the beginnings of file names. 
   local function expand_files(files)
      local res, bad_rockspecs = {}, {}

      local function add(file)
         table.insert(res, (file:gsub("^./", "")))
      end

      for _, file in ipairs(files) do
         if file == "-" then
            table.insert(res, io.stdin)
         elseif fs.is_dir(file) then
            for _, nested_file in ipairs(fs.extract_files(file, "%.lua$")) do
               add(nested_file)
            end
         elseif file:sub(-#".rockspec") == ".rockspec" then
            local related_files, err = expand_rockspec(file)

            if related_files then
               for _, related_file in ipairs(related_files) do
                  add(related_file)
               end
            else
               add(file)
               bad_rockspecs[#res] = err
            end
         else
            add(file)
         end
      end

      return res, bad_rockspecs
   end

   -- Config must support special metatables for some keys:
   -- autovivification for `files`, fallback to built-in stds for `stds`.
   -- Save values assigned to these globals to hidden keys.
   local special_keys = {stds = {}, files = {}}
   local special_mts = {stds = {__index = stds}, files = {__index = function(self, k)
      self[k] = {}
      return self[k]
   end}}
   local config_env_mt = {__newindex = function(self, k, v)
      if special_keys[k] then
         if type(v) == "table" then
            setmetatable(v, special_mts[k])
         end

         k = special_keys[k]
      end

      rawset(self, k, v)
   end, __index = function(self, k)
      if special_keys[k] then
         return self[special_keys[k]]
      end
   end}

   local function make_config_env()
      local env = setmetatable({}, config_env_mt)
      env.files = {}
      env.stds = {}
      -- Expose `require` so that custom stds or configuration could be loaded from modules.
      env.require = require
      return env
   end

   -- Returns nil or config, config_path, optional relative path from config to current directory.
   local function get_config(config_path)
      local rel_path

      if not config_path then
         local current_dir = fs.current_dir()
         local config_dir = fs.find_file(current_dir, default_config)

         if not config_dir then
            return
         end

         if config_dir == current_dir then
            config_path = default_config
         else
            config_path = config_dir .. default_config
            rel_path = current_dir:sub(#config_dir + 1)
         end
      end

      local env = make_config_env()
      local ok, ret = utils.load_config(config_path, env)

      if not ok then
         fatal(("Couldn't load configuration from %s: %s error"):format(config_path, ret))
      end

      if type(ret) == "table" then
         utils.update(env, ret)
      end

      rawset(env, "files", env[special_keys.files])

      if type(env[special_keys.stds]) == "table" then
         utils.update(stds, env[special_keys.stds])
      end

      return env, config_path, rel_path
   end

   local function validate_args(args, parser)
      if args.jobs and args.jobs < 1 then
         parser:error("<jobs> must be at least 1")
      end

      if args.std and not options.split_std(args.std) then
         parser:error("<std> must name a standard library")
      end
   end

   local function get_options(args)
      local res = {}

      for _, argname in ipairs {"allow_defined", "allow_defined_top", "module", "compat", "std"} do
         if args[argname] then
            res[argname] = args[argname]
         end
      end

      for _, argname in ipairs {"global", "unused", "redefined", "unused", "unused_args",
            "unused_secondaries", "self", "inline"} do
         if args["no_"..argname] then
            res[argname] = false
         end
      end

      for _, argname in ipairs {"globals", "read_globals", "new_globals", "new_read_globals",
            "ignore", "enable", "only"} do
         if #args[argname] > 0 then
            res[argname] = utils.concat_arrays(args[argname])
         end
      end

      return res
   end

   -- Applies cli-specific options from config to args.
   local function combine_config_and_args(config, args)
      if args.no_color then
         args.color = false
      else
         args.color = not config or (config.color ~= false)
      end

      args.codes = args.codes or config and config.codes
      args.formatter = args.formatter or (config and config.formatter) or "default"

      if args.no_cache or not fs.has_lfs then
         args.cache = false
      else
         args.cache = args.cache or (config and config.cache)
      end

      if args.cache == true then
         args.cache = default_cache_path
      end

      args.jobs = args.jobs or (config and config.jobs)
   end

   -- Returns sparse array of mtimes and map of filenames to cached reports.
   local function get_mtimes_and_cached_reports(cache_filename, files, bad_files)
      local cache_files = {}
      local cache_mtimes = {}
      local sparse_mtimes = {}

      for i, file in ipairs(files) do
         if not bad_files[i] and file ~= io.stdin then
            table.insert(cache_files, file)
            local mtime = fs.mtime(file)
            table.insert(cache_mtimes, mtime)
            sparse_mtimes[i] = mtime
         end
      end

      return sparse_mtimes, cache.load(cache_filename, cache_files, cache_mtimes) or fatal(
         ("Couldn't load cache from %s: data corrupted"):format(cache_filename))
   end

   -- Returns sparse array of sources of files that need to be checked, updates bad_files with files that had I/O issues.
   local function get_srcs_to_check(cached_reports, files, bad_files)
      local res = {}

      for i, file in ipairs(files) do
         if not bad_files[i] and not cached_reports[file] then
            local src = utils.read_file(file)

            if src then
               res[i] = src
            else
               bad_files[i] = "I/O"
            end
         end
      end

      return res
   end

   local function get_report(source)
      local report, err = luacheck.get_report(source)

      if report then
         return report
      else
         err.error = "syntax"
         return err
      end
   end

   -- Returns sparse array of new reports.
   local function get_new_reports(files, srcs, jobs)
      local dense_srcs = {}
      local dense_to_sparse = {}

      for i in ipairs(files) do
         if srcs[i] then
            table.insert(dense_srcs, srcs[i])
            dense_to_sparse[#dense_srcs] = i
         end
      end

      local map = jobs and multithreading.has_lanes and multithreading.pmap or utils.map
      local dense_res = map(get_report, dense_srcs, jobs)

      local res = {}

      for i in ipairs(dense_srcs) do
         res[dense_to_sparse[i]] = dense_res[i]
      end

      return res
   end

   -- Updates cache with new_reports. Updates bad_files for which mtime is absent.
   local function update_cache(cache_filename, files, bad_files, srcs, mtimes, new_reports)
      local cache_files = {}
      local cache_mtimes = {}
      local cache_reports = {}

      for i, file in ipairs(files) do
         if srcs[i] and file ~= io.stdin then
            if not mtimes[i] then
               bad_files[i] = "I/O"
            else
               table.insert(cache_files, file)
               table.insert(cache_mtimes, mtimes[i])
               table.insert(cache_reports, new_reports[i] or false)
            end
         end
      end

      return cache.update(cache_filename, cache_files, cache_mtimes, cache_reports) or fatal(
         ("Couldn't save cache to %s: I/O error"):format(cache_filename))
   end

   -- Returns array of reports for files.
   local function get_reports(cache_filename, files, bad_rockspecs, jobs)
      local bad_files = utils.update({}, bad_rockspecs)
      local mtimes
      local cached_reports

      if cache_filename then
         mtimes, cached_reports = get_mtimes_and_cached_reports(cache_filename, files, bad_files)
      else
         cached_reports = {}
      end

      local srcs = get_srcs_to_check(cached_reports, files, bad_files)
      local new_reports = get_new_reports(files, srcs, jobs)

      if cache_filename then
         update_cache(cache_filename, files, bad_files, srcs, mtimes, new_reports)
      end

      local res = {}

      for i, file in ipairs(files) do
         if bad_files[i] then
            res[i] = {error = bad_files[i]}
         else
            res[i] = cached_reports[file] or new_reports[i]
         end
      end

      return res
   end

   local function combine_config_and_options(config, config_path, config_rel_path, cli_opts, files)
      if not config then
         return cli_opts
      end

      config_rel_path = config_rel_path or ""

      local function validate(option_set, opts)
         local ok, invalid_field = options.validate(option_set, opts)

         if not ok then
            if invalid_field then
               fatal(("Couldn't load configuration from %s: invalid value of option '%s'"):format(
                  config_path, invalid_field))
            else
               fatal(("Couldn't load configuration from %s: validation error"):format(config_path))
            end
         end
      end

      validate(options.top_config_options, config)
      local res = {}

      for i, file in ipairs(files) do
         res[i] = {config}

         if type(config.files) == "table" and type(file) == "string" then
            file = config_rel_path .. file
            local overriding_paths = {}

            for path in pairs(config.files) do
               if file:sub(1, #path) == path then
                  table.insert(overriding_paths, path)
               end
            end

            -- Since all paths are prefixes of path, sorting by len is equivalent to regular sorting.
            table.sort(overriding_paths)

            -- Apply overrides from less specific (shorter prefixes) to more specific (longer prefixes).
            for _, path in ipairs(overriding_paths) do
               local overriding_config = config.files[path]
               validate(options.config_options, overriding_config)
               table.insert(res[i], overriding_config)
            end
         end

         table.insert(res[i], cli_opts)
      end

      return res
   end

   local function normalize_filenames(files)
      for i, file in ipairs(files) do
         if type(file) ~= "string" then
            files[i] = "stdin"
         end
      end
   end

   local builtin_formatters = utils.array_to_set({"TAP", "JUnit", "plain", "default"})

   local function pformat(report, file_names, args)
      if builtin_formatters[args.formatter] then
         return format(report, file_names, args)
      end

      local formatter = args.formatter
      local ok, output

      if type(formatter) == "string" then
         ok, formatter = pcall(require, formatter)

         if not ok then
            fatal(("Couldn't load custom formatter '%s': %s"):format(args.formatter, formatter))
         end
      end

      ok, output = pcall(formatter, report, file_names, args)

      if not ok then
         fatal(("Couldn't run custom formatter '%s': %s"):format(tostring(args.formatter), output))
      end

      return output
   end

   local parser = get_parser()
   local args = parser:parse()
   local opts = get_options(args)
   local config
   local config_path
   local config_rel_path

   if not args.no_config then
      config, config_path, config_rel_path = get_config(args.config)
   end

   validate_args(args, parser)
   combine_config_and_args(config, args)

   local files, bad_rockspecs = expand_files(args.files)
   local reports = get_reports(args.cache, files, bad_rockspecs, args.jobs)
   local report = luacheck.process_reports(reports, combine_config_and_options(config, config_path, config_rel_path, opts, files))
   normalize_filenames(files)

   local output = pformat(report, files, args)

   if #output > 0 and output:sub(-1) ~= "\n" then
      output = output .. "\n"
   end

   io.stdout:write(output)

   local exit_code

   if report.errors > 0 then
      exit_code = 2
   elseif report.warnings > 0 then
      exit_code = 1
   else
      exit_code = 0
   end

   os.exit(exit_code)
end

xpcall(main, global_error_handler)
