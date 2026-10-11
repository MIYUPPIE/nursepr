defmodule NursePrep.Questions.Ingestion.DocxParser do
  @moduledoc """
  Parses a pandoc JSON AST into structured question/option/answer data.

  Produce the input with:

      pandoc source.docx -t json --extract-media=<media_dir> -o source.json

  The source documents (raw NMCN-style past-question docx files) are
  inconsistently formatted: some options are nested nu­mbered lists, some are
  plain paragraphs hand-typed with a "(a)" prefix, some questions are
  fill-in-the-blank with no options at all, a handful reference embedded
  diagrams, and section labels contain typos ("SECTION V" instead of "F",
  "SECTIN J" instead of "J"). Rather than fight every inconsistency with more
  special-casing, this parser tracks section boundaries by *ordinal position*
  (the Nth "SECTION ..." header encountered, in document order) instead of by
  matching the label text, and pairs the Nth questions-header with the Nth
  answers-header that follows it. Anything that still doesn't resolve cleanly
  is surfaced in the run summary rather than guessed at-nothing here decides
  what's "probably right," that's the review queue's job.
  """

  @type option :: %{label: String.t(), text: String.t(), has_image: boolean()}

  @type question :: %{
          section_ordinal: pos_integer(),
          section_label: String.t() | nil,
          question_number: pos_integer(),
          stem: String.t(),
          has_image: boolean(),
          image_refs: [String.t()],
          options: [option()],
          answer_label: String.t() | nil,
          question_type: :mcq | :fill_blank | :unresolved
        }

  @doc "Reads and parses a pandoc JSON file, returning `{questions, image_notes, summary}`."
  @spec parse_file(Path.t()) :: {[question()], [map()], map()}
  def parse_file(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("blocks")
    |> parse_blocks()
  end

  @doc "Parses an already-decoded list of pandoc JSON blocks."
  @spec parse_blocks([map()]) :: {[question()], [map()], map()}
  def parse_blocks(blocks) do
    blocks = merge_split_headers(blocks)

    initial = %{
      section_ordinal: 0,
      section_label: nil,
      mode: :questions,
      current: nil,
      questions: [],
      # %{ {section_ordinal, question_number} => answer_label }
      answers: %{},
      image_notes: [],
      other_block_count: 0
    }

    final = Enum.reduce(blocks, initial, &handle_block/2)

    questions =
      final.questions |> Enum.reverse() |> Enum.map(&finalize_question(&1, final.answers))

    summary = %{
      total_sections: final.section_ordinal,
      total_questions: length(questions),
      mcq: Enum.count(questions, &(&1.question_type == :mcq)),
      fill_blank: Enum.count(questions, &(&1.question_type == :fill_blank)),
      unresolved: Enum.count(questions, &(&1.question_type == :unresolved)),
      with_image: Enum.count(questions, & &1.has_image),
      missing_answer: Enum.count(questions, &is_nil(&1.answer_label)),
      image_notes: length(final.image_notes),
      other_top_level_blocks_skipped: final.other_block_count
    }

    {questions, Enum.reverse(final.image_notes), summary}
  end

  # -- Block dispatch --------------------------------------------------------

  defp handle_block(%{"t" => "Para"} = block, state) do
    text = block_text(block)

    cond do
      section_header?(text) ->
        # The QUESTIONS-header and its paired ANSWERS-header for the same
        # logical section must resolve to the same `section_ordinal`, since
        # that's the join key between a question and its answer-key table.
        # Only the QUESTIONS-side header starts a new section; the
        # ANSWERS-side header (however it's spelled/typo'd) just flips mode.
        is_answer_header = String.contains?(String.upcase(text), "ANSWER")

        %{
          state
          | section_ordinal:
              if(is_answer_header, do: state.section_ordinal, else: state.section_ordinal + 1),
            section_label: text,
            mode: if(is_answer_header, do: :answers, else: :questions),
            current: nil
        }

      has_image?(block) and state.mode == :questions ->
        note = %{
          section_ordinal: state.section_ordinal,
          section_label: state.section_label,
          text: text,
          image_paths: image_paths(block)
        }

        state = %{state | image_notes: [note | state.image_notes]}

        case state.current do
          nil ->
            state

          current ->
            updated = %{
              current
              | has_image: true,
                image_refs: image_paths(block) ++ current.image_refs
            }

            %{state | current: updated, questions: [updated | tl(state.questions)]}
        end

      state.mode == :questions and state.current ->
        case option_line(text) do
          {label, option_text} ->
            option = %{label: label, text: option_text, has_image: has_image?(block)}
            updated = Map.update!(state.current, :options, &(&1 ++ [option]))
            %{state | current: updated, questions: [updated | tl(state.questions)]}

          nil ->
            %{state | other_block_count: state.other_block_count + 1}
        end

      true ->
        %{state | other_block_count: state.other_block_count + 1}
    end
  end

  defp handle_block(%{"t" => "OrderedList", "c" => [[start, style, _delim], items]}, state) do
    case {list_style(style), state.mode} do
      {:decimal, :questions} ->
        Enum.reduce(Enum.with_index(items, start), state, fn {item_blocks, number}, acc ->
          add_question(acc, number, item_blocks)
        end)

      {:lower_alpha, :questions} when not is_nil(state.current) ->
        options = build_options(items, start)
        updated = Map.update!(state.current, :options, &(&1 ++ options))
        %{state | current: updated, questions: [updated | tl(state.questions)]}

      {:decimal, :answers} ->
        answers =
          items
          |> Enum.with_index(start)
          |> Enum.reduce(state.answers, fn {item_blocks, number}, acc ->
            case extract_answer_letter(item_blocks) do
              {:ok, letter} -> Map.put(acc, {state.section_ordinal, number}, letter)
              :error -> acc
            end
          end)

        %{state | answers: answers}

      _ ->
        %{state | other_block_count: state.other_block_count + 1}
    end
  end

  defp handle_block(%{"t" => "Table"} = table, %{mode: :answers} = state) do
    pairs = extract_answer_pairs(table)

    answers =
      Enum.reduce(pairs, state.answers, fn {number, label}, acc ->
        Map.put(acc, {state.section_ordinal, number}, label)
      end)

    %{state | answers: answers}
  end

  defp handle_block(_block, state), do: %{state | other_block_count: state.other_block_count + 1}

  # -- Question / option construction ----------------------------------------

  defp add_question(state, number, item_blocks) do
    {stem_parts, has_image, image_refs, nested_options} = walk_item_blocks(item_blocks)

    question = %{
      section_ordinal: state.section_ordinal,
      section_label: state.section_label,
      question_number: number,
      stem: Enum.join(stem_parts, " ") |> String.trim(),
      has_image: has_image,
      image_refs: image_refs,
      options: nested_options,
      answer_label: nil,
      question_type: :unresolved
    }

    %{state | current: question, questions: [question | state.questions]}
  end

  # Walks one OrderedList item's own block list: its Para(s) are the stem, a
  # nested OrderedList (when present) is that same question's options.
  defp walk_item_blocks(item_blocks) do
    Enum.reduce(item_blocks, {[], false, [], []}, fn
      %{"t" => t} = b, {stem, img, refs, opts} when t in ["Para", "Plain"] ->
        text = block_text(b)
        {stem ++ [text], img or has_image?(b), refs ++ image_paths(b), opts}

      %{"t" => "OrderedList", "c" => [[start, style, _delim], sub_items]},
      {stem, img, refs, opts} ->
        case list_style(style) do
          :lower_alpha -> {stem, img, refs, opts ++ build_options(sub_items, start)}
          _ -> {stem, img, refs, opts}
        end

      %{"t" => "BlockQuote", "c" => inner}, {stem, img, refs, opts} ->
        {inner_stem, inner_img, inner_refs, _} = walk_item_blocks(inner)
        {stem ++ inner_stem, img or inner_img, refs ++ inner_refs, opts}

      _other, acc ->
        acc
    end)
  end

  defp build_options(items, start) do
    items
    |> Enum.with_index(start)
    |> Enum.map(fn {item_blocks, idx} ->
      {stem_parts, has_image, _refs, _} = walk_item_blocks(item_blocks)

      %{
        label: alpha_label(idx),
        text: Enum.join(stem_parts, " ") |> String.trim(),
        has_image: has_image
      }
    end)
  end

  defp alpha_label(idx) when idx >= 1, do: <<?A + idx - 1>>

  defp finalize_question(question, answers) do
    answer_label = Map.get(answers, {question.section_ordinal, question.question_number})

    question_type =
      cond do
        length(question.options) >= 2 -> :mcq
        blank_pattern?(question.stem) -> :fill_blank
        true -> :unresolved
      end

    %{question | answer_label: answer_label, question_type: question_type}
  end

  # Matches runs of ASCII dots/underscores as typed in the source, and the
  # Unicode horizontal-ellipsis character some text-processing round-trips
  # (including pandoc's own markdown reader) collapse "..." into.
  defp blank_pattern?(stem), do: String.match?(stem, ~r/\.{3,}|_{3,}|…/)

  # -- Answer table extraction -------------------------------------------------

  # Pandoc Table AST: [attr, caption, colspecs, thead, tbodies, tfoot]
  # thead/tbody rows are `[row_attr, cells]`; each cell is
  # `[attr, alignment, rowspan, colspan, blocks]`. Answer tables alternate
  # question-number cells (containing a nested OrderedList whose start index
  # is the question number) with answer-letter cells (a bare Plain/Str).
  defp extract_answer_pairs(%{"c" => [_attr, _caption, _colspecs, thead, tbodies, _tfoot]}) do
    head_rows = table_rows(thead)
    body_rows = Enum.flat_map(tbodies, &table_body_rows/1)

    (head_rows ++ body_rows)
    |> Enum.flat_map(&row_cells/1)
    |> Enum.map(&cell_blocks/1)
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [num_cell, letter_cell] -> pair_from_cells(num_cell, letter_cell)
      _ -> []
    end)
  end

  defp extract_answer_pairs(_), do: []

  # A second answer-key format found in the real source: instead of a
  # Table, the answer for question N is a single-item decimal OrderedList
  # starting at N (the same "start index is the question number" trick
  # `extract_ordered_list_start/1` reads out of table cells, just at the
  # top level instead of nested in a cell). These lists are frequently
  # interspersed with stray Para blocks (leftover option/diagram-label
  # text) that aren't answers at all, and even within one list some items
  # are the clean single letter a real MCQ answer needs while others are
  # free-text (diagram-labeling answers like "Cortex/Medulla" with no
  # option letter). Only accept a bare letter, optionally followed by
  # `.`/`)` and more text ("B", "A. lobules")-anything else is left
  # unresolved rather than guessed at, e.g. "FALSE PELVIS" must not be
  # misread as answer "F".
  defp extract_answer_letter(item_blocks) do
    text = item_blocks |> Enum.map(&block_text/1) |> Enum.join(" ") |> String.trim()

    case Regex.run(~r/^([A-Fa-f])(?:[.)]\s*.*)?$/, text) do
      [_, letter] -> {:ok, String.upcase(letter)}
      nil -> :error
    end
  end

  defp table_rows([_attr, rows]), do: rows
  defp table_rows(_), do: []

  # TableBody: [attr, row_head_columns, intermediate_head_rows, body_rows]
  defp table_body_rows([_attr, _row_head_columns, head_rows, body_rows]),
    do: head_rows ++ body_rows

  defp table_body_rows(_), do: []

  defp row_cells([_attr, cells]), do: cells
  defp row_cells(_), do: []

  defp cell_blocks([_attr, _align, _rowspan, _colspan, blocks]), do: blocks
  defp cell_blocks(_), do: []

  defp pair_from_cells(num_blocks, letter_blocks) do
    with {:ok, number} <- extract_ordered_list_start(num_blocks),
         {:ok, letter} <- extract_plain_text(letter_blocks) do
      [{number, String.trim(letter)}]
    else
      _ -> []
    end
  end

  # The question-number cell is usually a nested OrderedList whose start index
  # is the number (verified against the real source). But not every answer
  # table necessarily uses that formatting, so fall back to reading a bare
  # leading integer out of the cell's plain text ("1", "1.") if no list is
  # found, rather than silently losing the row.
  defp extract_ordered_list_start(blocks) do
    Enum.find_value(blocks, :error, fn
      %{"t" => "OrderedList", "c" => [[start, _style, _delim], _items]} -> {:ok, start}
      _ -> nil
    end)
    |> case do
      {:ok, start} -> {:ok, start}
      :error -> extract_leading_integer(blocks)
    end
  end

  defp extract_leading_integer(blocks) do
    text = blocks |> Enum.map(&block_text/1) |> Enum.join("")

    case Regex.run(~r/^\s*(\d+)/, text) do
      [_, digits] -> {:ok, String.to_integer(digits)}
      nil -> :error
    end
  end

  defp extract_plain_text([%{"t" => "Plain"} = b | _]), do: {:ok, block_text(b)}
  defp extract_plain_text([%{"t" => "Para"} = b | _]), do: {:ok, block_text(b)}
  defp extract_plain_text(_), do: :error

  # -- Text / inline helpers ---------------------------------------------------

  defp block_text(%{"t" => t, "c" => inlines}) when t in ["Para", "Plain"] do
    inlines |> Enum.map(&inline_text/1) |> Enum.join("") |> String.trim()
  end

  defp block_text(_), do: ""

  defp inline_text(%{"t" => "Str", "c" => s}), do: s
  defp inline_text(%{"t" => t}) when t in ["Space", "SoftBreak", "LineBreak"], do: " "

  defp inline_text(%{"t" => t, "c" => inlines})
       when t in ["Emph", "Strong", "Underline", "Strikeout"],
       do: inlines |> Enum.map(&inline_text/1) |> Enum.join("")

  defp inline_text(%{"t" => "Image"}), do: ""
  defp inline_text(_), do: ""

  defp has_image?(%{"t" => t, "c" => inlines}) when t in ["Para", "Plain"],
    do: Enum.any?(inlines, &match?(%{"t" => "Image"}, &1))

  defp has_image?(_), do: false

  defp image_paths(%{"t" => t, "c" => inlines}) when t in ["Para", "Plain"] do
    Enum.flat_map(inlines, fn
      %{"t" => "Image", "c" => [_attr, _caption, [target, _title]]} -> [target]
      _ -> []
    end)
  end

  defp image_paths(_), do: []

  # Deliberately loose: the source has typo'd section labels ("SECTIODN D;
  # OBJECTIVES", "SECTIN J", "SECTION N;"). Matching on a fuzzy "SECTI" prefix
  # plus a separator, rather than an exact hand-built label lookup, catches
  # all observed variants without needing to enumerate every typo by hand.
  defp section_header?(text) do
    byte_size(text) < 80 and String.match?(text, ~r/^SECTI\w{0,4}[\s:;.,]/i)
  end

  @bare_header_continuations ["ANSWERS", "ANSWER", "QUESTIONS", "QUESTION"]

  # Handles the split-header case found in the source, e.g. block N is the
  # Para "SECTION C: OBJECTIVE" and block N+1 is a standalone Para reading
  # just "ANSWERS"-two blocks that are really one logical header. Merging
  # them before the main walk means the rest of the parser only ever has to
  # reason about one header shape.
  defp merge_split_headers(blocks) do
    blocks
    |> Enum.reduce([], fn block, acc ->
      with %{"t" => "Para"} <- block,
           curr_text = block_text(block),
           true <- String.upcase(String.trim(curr_text)) in @bare_header_continuations,
           [%{"t" => "Para"} = prev | rest] <- acc,
           prev_text = block_text(prev),
           true <- section_header?(prev_text),
           false <- String.contains?(String.upcase(prev_text), ["ANSWER", "QUESTION"]) do
        merged = %{
          "t" => "Para",
          "c" => [%{"t" => "Str", "c" => prev_text <> " " <> String.trim(curr_text)}]
        }

        [merged | rest]
      else
        _ -> [block | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp list_style(%{"t" => "Decimal"}), do: :decimal
  defp list_style(%{"t" => "LowerAlpha"}), do: :lower_alpha
  defp list_style(%{"t" => "UpperAlpha"}), do: :upper_alpha
  defp list_style(_), do: :other

  defp option_line(text) do
    case Regex.run(~r/^\(?([a-dA-D])[\.\)]\s*(.+)$/, text) do
      [_, label, option_text] -> {String.upcase(label), option_text}
      nil -> nil
    end
  end
end
