defmodule Mneme.Learner.CodingAgent.Util do
  @moduledoc false

  def parse_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      ["", yaml_str, body] ->
        frontmatter =
          yaml_str
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&parse_yaml_line/1)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {frontmatter, String.trim(body)}

      _ ->
        {%{}, String.trim(content)}
    end
  end

  defp parse_yaml_line(line) do
    case Regex.run(~r/^(\w[\w\s]*):\s*(.+)$/, String.trim(line)) do
      [_, key, value] ->
        {String.trim(key), unquote_yaml(value)}

      _ ->
        nil
    end
  end

  defp unquote_yaml(value) do
    v = String.trim(value)

    cond do
      String.starts_with?(v, "\"") and String.ends_with?(v, "\"") ->
        String.slice(v, 1..-2//1)

      String.starts_with?(v, "'") and String.ends_with?(v, "'") ->
        String.slice(v, 1..-2//1)

      true ->
        v
    end
  end

  def expand(path), do: Path.expand(path)

  def dir_exists?(path), do: File.dir?(expand(path))

  def read_file(path, max_bytes \\ 8000) do
    case File.read(path) do
      {:ok, content} -> {:ok, String.slice(content, 0, max_bytes)}
      error -> error
    end
  end

  def short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  def short_id(id), do: id

  def project_tag(project) when is_binary(project) do
    display =
      project
      |> String.trim_leading("-")
      |> String.replace("-", "/")
      |> String.replace_prefix("/", "")

    "project:#{display}"
  end

  def project_tag(_), do: "project:unknown"

  def extract_jsonl_lines(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode/1)
    |> Enum.flat_map(fn
      {:ok, obj} -> [obj]
      _ -> []
    end)
  end

  def extract_user_text_from_json(obj) do
    type = Map.get(obj, "type")

    if type == "user" and not Map.get(obj, "isMeta", false) do
      msg = Map.get(obj, "message", %{})
      content = Map.get(msg, "content", "")
      pull_user_text(content)
    else
      []
    end
  end

  defp pull_user_text(content) when is_binary(content) do
    case Regex.run(~r/<user_prompt>\s*(.*?)\s*<\/user_prompt>/s, content) do
      [_, prompt] ->
        cleaned =
          prompt
          |> String.replace(~r/\[.*?\]\(.*?\)/, "")
          |> String.trim()

        if cleaned != "" and String.length(cleaned) > 10, do: [cleaned], else: []

      _ ->
        []
    end
  end

  defp pull_user_text(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} -> pull_user_text(text)
      _ -> []
    end)
  end

  defp pull_user_text(_), do: []
end
