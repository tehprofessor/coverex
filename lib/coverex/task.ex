defmodule Coverex.Task do
    require EEx

    require Logger
    @doc """
    Starts the `Coverex` coverage data generation. An additional option
    is 

        log: :error

    which sets the log-level of the Elixir Logger application. Default value
    is `:error`. For debugging purposes, it can be set to :debug. In this case, 
    the output is quite noisy...
    """
    def start(compile_path, opts) do
      Mix.shell.info "Coverex compiling modules ... "
      Mix.shell.info "compile_path is #{inspect compile_path}"
      Mix.shell.info "Options are: #{inspect opts}"
      :cover.start
      :cover.compile_beam_directory(compile_path |> to_char_list)

      if :application.get_env(:cover, :started) != {:ok, true} do
        :application.set_env(:cover, :started, true)
      end        
        
      output = opts[:output]
      fn() ->
        Mix.shell.info "\nGenerating cover results ... "
        Application.ensure_started(:logger)
        Logger.configure(level: Keyword.get(opts, :log, :error))
        File.mkdir_p!(output)
        Enum.each :cover.modules, fn(mod) ->
          # :cover.analyse_to_file(mod, '#{output}/#{mod}.1.html', [:html])
          write_html_file(mod, output)
        end
        Mix.shell.info "before missing files"
        {mods, funcs} = coverage_data()
        write_module_overview(mods, output)
        write_function_overview(funcs, output)
        Mix.shell.info "after files"
        generate_assets(output)
        # ask for coveralls option
        if (running_travis?() and post_to_coveralls?(opts)) do
          post_coveralls(:cover.modules, output, travis_job_id())
        end
      end
    end
    
    @doc "is post to coveralls requested?"
    def post_to_coveralls?(opts) do
      Keyword.get(opts, :coveralls, false)
    end
    
    @spec running_travis?(%{String.t => String.t}) :: String.t
    def running_travis?(env \\ System.get_env()) do
      case env["TRAVIS"] do 
        "true" -> true
        _ -> false
      end
    end

    @doc "gets the travis job id out of the environment"
    @spec travis_job_id(%{String.t => String.t}) :: String.t
    def travis_job_id(env \\ System.get_env()) do
      env["TRAVIS_JOB_ID"]      
    end

    @spec post_coveralls([atom], String.t, String.t, String.t) :: :ok
    def post_coveralls(mods, output, job_id, url \\ "https://coveralls.io/api/v1/jobs") do
      IO.puts "post to coveralls"
      Application.ensure_all_started(:httpoison)
      source = Coverex.Source.coveralls_data(mods)
      body = Poison.encode!(%{
        :service_name => "travis-ci",
        :service_job_id => job_id,
        :source_files => source
        })
      filename = "./#{output}/coveralls.json"
      File.write(filename, body)
      response = send_http(url, filename, body)
      IO.puts("Response: #{inspect response}")
    end

    def send_http(url, filename, _body) do
      HTTPoison.post(url, 
        {:multipart, [
          {:file, filename, 
            {"form-data", [{"name", "json_file"}, {"filename", filename}]},
            [{"Content-Type", "application/json"}]
          }
        ]})
    end

    def write_html_file(mod, output) do
      {entries, source} = Coverex.Source.analyze_to_html(mod)
      {:ok, s} = StringIO.open(source)
      lines = Stream.zip(numbers, IO.stream(s, :line)) |> Stream.map(fn({n, line}) -> 
        case Map.get(entries, n, nil) do
          {count, anchor} -> {n, {encode_html(line), count, anchor}}
          nil -> {n, {encode_html(line), nil, nil}}
        end
      end) |> Enum.map(&(&1))

      # IO.inspect(lines)
      content = source_template(mod, lines)
      File.write("#{output}/#{mod}.html", content)
    end
    
    # all positive numbers
    defp numbers(), do: Stream.iterate(1, &(&1+1))

    def encode_html(s, acc \\ "")
    def encode_html("", acc), do: acc
    def encode_html(s, acc) do
      {first, rest} = String.next_grapheme(s)
      case first do
        ">" -> encode_html(rest, acc <> "&gt;") 
        "<" -> encode_html(rest, acc <> "&lt;")
        "&" -> encode_html(rest, acc <> "&amp;")
        nil -> acc
        any -> encode_html(rest, acc <> any)
      end
    end 

    def write_module_overview(modules, output) do
      Mix.shell.info "Writing module overview: #{output}/modules.html"
      mods = Enum.map(modules, fn({mod, v}) -> {module_link(mod), v} end)
      content = overview_template("Modules", mods)
      IO.puts content
      File.write("#{output}/modules.html", content)
    end

    def write_function_overview(functions, output) do
      Mix.shell.info "Writing function overview: #{output}/functions.html"
      funs = Enum.map(functions, fn({{m,f,a}, v}) -> {module_link(m, f, a), v} end)
      content = overview_template("Functions", funs)
      IO.puts content
      File.write("#{output}/functions.html", content)
    end
    
    defp module_link(mod), do: "<a href=\"#{mod}.html\">#{mod}</a>"
    defp module_link(m, f, a), do: "<a href=\"#{m}.html##{m}.#{f}.#{a}\">#{m}.#{f}/#{a}</a>"

    def module_anchor({m, f, a}), do: "<a name=\"##{m}.#{f}.#{a}\"></a>"
    def module_anchor(m), do: "<a name=\"##{m}\"></a>"

    def cover_class(nil), do: "irrelevant"
    def cover_class(0), do: "not_covered"
    def cover_class(_n), do: "covered"

    @doc """
    Returns detailed coverage data `{mod, mf}` for all modules from the `:cover` application. 

    ## The `mod` data
    The `mod` data is a list of pairs: `{modulename, {no of covered lines, no of uncovered lines}}`
  
    ## The `mf` data
    The `mf` data is list of pairs: `{{m, f, a}, {no of covered lines, no of uncovered lines}}`

    """
    def coverage_data() do
      modules = Enum.map(:cover.modules, fn(mod) ->
        {:ok, {m, {cov, noncov}}} = :cover.analyse(mod, :coverage, :module) 
        {m, {cov, noncov}}
      end) |> Enum.sort
      mfunc = Enum.flat_map(:cover.modules, fn(mod) ->
        {:ok, funcs} = :cover.analyse(mod, :coverage, :function)
        funcs
      end) |> Enum.sort
      {modules, mfunc}
    end

    ## Generate templating functions via EEx, borrowd from ex_doc
    templates = [
      overview_template: [:title, :entries],
      overview_entry_template: [:entry, :cov, :uncov, :ratio],
      source_template: [:title, :lines],
      source_line_template: [:number, :count, :source, :anchor]
    ]
    Enum.each templates, fn({ name, args }) ->
      filename = Path.expand("templates/#{name}.eex", __DIR__)
      EEx.function_from_file :def, name, filename, args
    end

    # generates asset files
    defp generate_assets(output) do
      Enum.each assets, fn({ pattern, dir }) ->
        output = "#{output}/#{dir}"
        File.mkdir output

        Enum.map Path.wildcard(pattern), fn(file) ->
          base = Path.basename(file)
          File.copy file, "#{output}/#{base}"
        end
      end
    end
    # assets are javascript, css and gif resources
    defp assets do
      [ { templates_path("css/*.css"), "css" },
        { templates_path("js/*.js"), "js" },
        { templates_path("css/*.gif"), "css" },
      ]
    end
    defp templates_path(other), do: Path.expand("templates/#{other}", __DIR__)

end
