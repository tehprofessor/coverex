defmodule Coverex.Source do
	@moduledoc """
	This module provides access to the source code the system to be analyzed.
	"""

	@type symbol :: :atom
	@type line_pairs :: %{symbol => pos_integer}
	@type modules :: %{symbol => line_pairs}

	@spec find_all_mods_and_funs(any) :: modules
	def find_all_mods_and_funs(qs) do
		acc = %{:Elixir => %{}}
		do_all_mods(:Elixir, qs, acc)
	end
	
	def do_all_mods(m, {:defmodule, [line: ln], [{:__aliases__, _, mod_name} | body]}, acc) do
		# IO.puts ("+++ Found module #{inspect mod_name}")
		mod = alias_to_atom(mod_name)
		do_all_mods(mod, body, acc |> Map.put(mod, %{} |> Map.put(mod,ln)))
	end
	def do_all_mods(m, {:def, [line: ln], [{fun_name, _, _args}, body]}, acc) do
		# IO.puts ("--- Found function #{inspect fun_name}")
		do_all_mods(m, body, acc |> put_in([m, fun_name], ln))
	end
	def do_all_mods(m, {:__block__, _, tree}, acc) when is_list(tree), do: do_all_mods(m, tree, acc)
	def do_all_mods(m, {:do, tree}, acc), do: do_all_mods(m, tree, acc)
	def do_all_mods(m, t = {t1, t2, t3}, acc) do
		# IO.puts "#### Found triple #{inspect t}"
		acc
	end
	def do_all_mods(m, [], acc), do: acc
	def do_all_mods(m, [ head | tree], acc) do
		# basic recursion of the tree
		acc1 = do_all_mods(m, head, acc)
		do_all_mods(m, tree, acc1)
	end
	def do_all_mods(m, t, acc) do
		# IO.puts ">>> Found tree #{inspect t}"
		acc
	end


	@doc "Returns the aliased module name if there are any dots in its name"
	def alias_mod(mod) when is_atom(mod) do
		mod |> Atom.to_string|> String.split(".") |> 
			Enum.drop(1) |> # first element contains "Elixir" which is not needed here!
			Enum.map &String.to_atom/1 
	end
	
	@doc "Returns the atom module name based on the alias list"
	def alias_to_atom(a) when is_list(a) do
		[:Elixir | a] |> Enum.map_join(".", &Atom.to_string/1) |> String.to_atom
	end
	

	def get_quoted_source(mod) do
		path = get_source_path(mod)
		{:ok, source} = File.read(path)
		{:ok, quoted} = Code.string_to_quoted(source)
		{quoted, source}
	end
	

	def get_source_path(mod) when is_atom(mod) do
		get_compile_info(mod) |> Keyword.get :source
	end
	
	def get_compile_info(mod) when is_atom(mod) do
		{^mod, beam, filename} = :code.get_object_code(mod)
		case :beam_lib.chunks(beam, [:compile_info]) do
			{:ok, {^mod, [{:compile_info, compile}]}} -> compile
			_ -> []
		end		
	end

end