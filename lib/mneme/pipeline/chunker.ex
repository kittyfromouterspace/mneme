defmodule Mneme.Pipeline.Chunker do
  @moduledoc """
  Splits document text into chunks suitable for embedding and retrieval.

  Uses a paragraph/section-based strategy with configurable target token count
  and overlap. Preserves section headings as context metadata.
  """

  @default_target_tokens 512
  @default_overlap_tokens 50
  @chars_per_token 4

  defstruct [
    :content,
    :sequence,
    :start_offset,
    :end_offset,
    :token_count,
    :heading_context
  ]

  @type t :: %__MODULE__{
          content: String.t(),
          sequence: non_neg_integer(),
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          token_count: non_neg_integer(),
          heading_context: String.t() | nil
        }

  @doc """
  Split text into chunks.

  ## Options
  - `:target_tokens` - target token count per chunk (default: #{@default_target_tokens})
  - `:overlap_tokens` - token overlap between chunks (default: #{@default_overlap_tokens})
  """
  @spec chunk(String.t(), keyword()) :: [t()]
  def chunk(text, opts \\ []) when is_binary(text) do
    target_tokens = Keyword.get(opts, :target_tokens, @default_target_tokens)
    overlap_tokens = Keyword.get(opts, :overlap_tokens, @default_overlap_tokens)
    target_chars = target_tokens * @chars_per_token
    overlap_chars = overlap_tokens * @chars_per_token

    text
    |> split_into_sections()
    |> build_chunks(target_chars, overlap_chars)
    |> Enum.with_index()
    |> Enum.map(fn {%__MODULE__{} = chunk, idx} ->
      %{chunk | sequence: idx}
    end)
  end

  @doc "Estimate the token count for a string."
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    max(div(String.length(text), @chars_per_token), 1)
  end

  # Split text into sections based on markdown headings and double newlines
  defp split_into_sections(text) do
    parts = Regex.split(~r/(?=^\#{1,4}\s)/m, text, include_captures: true)

    parts
    |> Enum.reduce({[], nil, 0}, fn part, {acc, current_heading, offset} ->
      trimmed = String.trim(part)

      if trimmed == "" do
        {acc, current_heading, offset + String.length(part)}
      else
        heading =
          case Regex.run(~r/^(\#{1,4}\s.+?)$/m, part) do
            [_, h] -> String.trim(h)
            _ -> current_heading
          end

        paragraphs = split_paragraphs(part, offset, heading)
        {acc ++ paragraphs, heading, offset + String.length(part)}
      end
    end)
    |> elem(0)
  end

  defp split_paragraphs(text, base_offset, heading) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.reduce({[], base_offset}, fn para, {acc, offset} ->
      trimmed = String.trim(para)

      if trimmed == "" do
        {acc, offset + String.length(para) + 2}
      else
        section = %{
          text: trimmed,
          heading: heading,
          offset: offset,
          length: String.length(trimmed)
        }

        {acc ++ [section], offset + String.length(para) + 2}
      end
    end)
    |> elem(0)
  end

  defp build_chunks(sections, target_chars, overlap_chars) do
    sections
    |> Enum.reduce({[], nil}, fn section, {chunks, current} ->
      if current == nil do
        {chunks, new_chunk(section)}
      else
        current_len = String.length(current.content)
        section_len = section.length

        if current_len + section_len + 1 <= target_chars do
          merged = %{
            current
            | content: current.content <> "\n\n" <> section.text,
              end_offset: section.offset + section.length,
              token_count: estimate_tokens(current.content <> "\n\n" <> section.text)
          }

          {chunks, merged}
        else
          overlap_text = extract_overlap(current.content, overlap_chars)

          new =
            if overlap_text == "" do
              new_chunk(section)
            else
              %__MODULE__{
                content: overlap_text <> "\n\n" <> section.text,
                sequence: 0,
                start_offset: max(current.end_offset - String.length(overlap_text), 0),
                end_offset: section.offset + section.length,
                token_count: estimate_tokens(overlap_text <> "\n\n" <> section.text),
                heading_context: section.heading || current.heading_context
              }
            end

          {chunks ++ [current], new}
        end
      end
    end)
    |> finalize_chunks()
  end

  defp new_chunk(section) do
    %__MODULE__{
      content: section.text,
      sequence: 0,
      start_offset: section.offset,
      end_offset: section.offset + section.length,
      token_count: estimate_tokens(section.text),
      heading_context: section.heading
    }
  end

  defp extract_overlap(text, overlap_chars) when overlap_chars > 0 do
    if String.length(text) <= overlap_chars do
      text
    else
      text
      |> String.slice(-overlap_chars..-1//1)
      |> then(fn overlap ->
        case String.split(overlap, ~r/\.\s+/, parts: 2) do
          [_, rest] -> rest
          _ -> overlap
        end
      end)
    end
  end

  defp extract_overlap(_, _), do: ""

  defp finalize_chunks({chunks, nil}), do: chunks
  defp finalize_chunks({chunks, current}), do: chunks ++ [current]
end
