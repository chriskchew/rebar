%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_otp_app).

-export([compile/2,
         clean/2,
         install/2]).

-include("rebar.hrl").

%% ===================================================================
%% Public API
%% ===================================================================

compile(_Config, File) ->
    %% If we get an .app.src file, it needs to be pre-processed and
    %% written out as a ebin/*.app file. That resulting file will then
    %% be validated as usual.
    case rebar_app_utils:is_app_src(File) of
        true ->
            AppFile = preprocess(File);
        false ->
            AppFile = File
    end,

    %% Load the app file and validate it.
    case rebar_app_utils:load_app_file(AppFile) of
        {ok, AppName, AppData} ->
            validate_name(AppName, AppFile),
            validate_modules(AppName, proplists:get_value(modules, AppData));
        {error, Reason} ->
            ?ABORT("Failed to load app file ~s: ~p\n", [AppFile, Reason])
    end.

clean(_Config, File) ->
    %% If the app file is a .app.src, delete the generated .app file
    case rebar_app_utils:is_app_src(File) of
        true ->
            file:delete(rebar_app_utils:app_src_to_app(File)),
            ok;
        false ->
            ok
    end.


install(Config, File) ->
    %% If we get an .app.src file, it needs to be pre-processed and
    %% written out as a ebin/*.app file. That resulting file will then
    %% be validated as usual.
    case rebar_app_utils:is_app_src(File) of
        true ->
            AppFile = preprocess(File);
        false ->
            AppFile = File
    end,

    %% Load the app name and version from the .app file and construct
    %% the app identifier
    {ok, AppName, AppData} = rebar_app_utils:load_app_file(AppFile),

    %% Validate the .app file prior to installation
    validate_name(AppName, AppFile),
    validate_modules(AppName, proplists:get_value(modules, AppData)),

    %% Get the target directory. The user can specify a target= directory
    %% on the command line for convenience, or it defaults to the Erlang
    %% install dir
    TargetDir = rebar_config:get_global(target, code:lib_dir()),

    %% Pull out the vsn and construct identifier
    Vsn = proplists:get_value(vsn, AppData),
    AppId = ?FMT("~s-~s", [AppName, Vsn]),
    ?CONSOLE("Installing: ~s to ~s\n", [AppId, TargetDir]),

    %% Check the erlang lib directory to see if this app identifier
    %% is already present.
    AppDir = filename:join([TargetDir, AppId]),
    case filelib:is_dir(AppDir) of
        true ->
            %% Already exists -- check for force=1 global flag and only
            %% continue if it's set
            case rebar_config:get_global(force, "0") of
                "0" ->
                    ?ERROR("~s already exists. Installation failed.\n", [AppId]),
                    ?FAIL;
                "1" ->
                    ?WARN("~s already exists, but forcibly overwriting.\n", [AppId])
            end;
        false ->
            ok
    end,

    %% Wipe out any previous versions
    ok = rebar_file_utils:rm_rf(AppDir),

    %% Re-create target
    ok = rebar_file_utils:mkdir_p(AppDir),

    %% By default we copy the ebin, include, src and priv directories (if they exist)
    Directories = lists:merge(["ebin", "src", "priv", "include"], rebar_config:get(Config, sub_dirs, [])),
    Files = [F || F <- Directories,
                  filelib:last_modified(F) /= 0],
    ok = rebar_file_utils:cp_r(Files, AppDir),

    %% Check the config to see if we have any binaries that need to be
    %% linked into the erlang path
    case rebar_config:get_list(Config, app_bin, []) of
        [] ->
            ok;
        List ->
            %% code:root_dir() gives $OTPROOT/lib/erlang on a stock install
            %% so find the bin dir relative to that.
            BinDir = filename:join([code:root_dir(), "..", "..", "bin"]),
            install_binaries(List, AppDir, BinDir)
    end.


%% ===================================================================
%% Internal functions
%% ===================================================================

install_binaries([], _AppDir, _BinDir) ->
    ok;
install_binaries([Bin | Rest], AppDir, BinDir) ->
    FqBin = filename:join([AppDir, Bin]),
    rebar_file_utils:ln_sf(FqBin, BinDir),
    install_binaries(Rest, AppDir, BinDir).

preprocess(AppSrcFile) ->
    case rebar_app_utils:load_app_file(AppSrcFile) of
        {ok, AppName, AppData} ->
            %% Get a list of all the modules available in ebin/ and update
            %% the app data accordingly
            A1 = lists:keystore(modules, 1, AppData, {modules, ebin_modules()}),

            %% Build the final spec as a string
            Spec = io_lib:format("~p.\n", [{application, AppName, A1}]),

            %% Setup file .app filename and write new contents
            AppFile = rebar_app_utils:app_src_to_app(AppSrcFile),
            ok = file:write_file(AppFile, Spec),
            AppFile;

        {error, Reason} ->
            ?ABORT("Failed to read ~s for preprocessing: ~p\n", [AppSrcFile, Reason])
    end.


validate_name(AppName, File) ->
    %% Convert the .app file name to an atom -- check it against the identifier within the file
    ExpApp = list_to_atom(filename:basename(File, ".app")),
    case ExpApp == AppName of
        true ->
            ok;
        false ->
            ?ERROR("Invalid ~s: name of application (~p) must match filename.\n",
                   [File, AppName]),
            ?FAIL
    end.

validate_modules(AppName, undefined) ->
            ?ERROR("Missing modules declaration in~p.app:\n", [AppName]),
            ?FAIL;

validate_modules(AppName, Mods) ->
    %% Construct two sets -- one for the actual .beam files in ebin/ and one for the modules
    %% listed in the .app file
    EbinSet = ordsets:from_list(ebin_modules()),
    ModSet = ordsets:from_list(Mods),

    %% Identify .beam files listed in the .app, but not present in ebin/
    case ordsets:subtract(ModSet, EbinSet) of
        [] ->
            ok;
        MissingBeams ->
            Msg1 = lists:flatten([io_lib:format("\t* ~p\n", [M]) || M <- MissingBeams]),
            ?ERROR("One or more modules listed in ~p.app are not present in ebin/*.beam:\n~s",
                   [AppName, Msg1]),
            ?FAIL
    end,

    %% Identify .beam files NOT list in the .app, but present in ebin/
    case ordsets:subtract(EbinSet, ModSet) of
        [] ->
            ok;
        MissingMods ->
            Msg2 = lists:flatten([io_lib:format("\t* ~p\n", [M]) || M <- MissingMods]),
            ?ERROR("One or more .beam files exist that are not listed in ~p.app:\n~s",
                   [AppName, Msg2]),
            ?FAIL
    end.

ebin_modules() ->
    lists:sort([rebar_utils:beam_to_mod("ebin", N) || N <- rebar_utils:beams("ebin")]).
