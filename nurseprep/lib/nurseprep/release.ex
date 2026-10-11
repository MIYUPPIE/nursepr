defmodule NursePrep.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :nurseprep

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc "Seeds the canonical NMCN subjects. Idempotent-safe to run more than once."
  def seed_subjects do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(NursePrep.Repo, fn _repo ->
        NursePrep.Questions.seed_canonical_subjects()
      end)

    result
  end

  @doc """
  Loads a question JSON file (see `NursePrep.Questions.Import`) straight
  into the DB as published.

      bin/nurseprep eval 'NursePrep.Release.import_questions_json()'

  Defaults to `priv/source_data/nursing_questions.json` *inside the
  release*-resolved via `Application.app_dir/2` rather than a hardcoded
  `/app/priv/...` path, since a compiled release namespaces each app's
  `priv/` under a version-specific directory
  (`_build/prod/rel/nurseprep/lib/nurseprep-<vsn>/priv/`), not a flat
  `/app/priv/`. Getting the file there is just a normal deploy: it's
  gitignored but present in the working tree at deploy time, so
  `bin/deploy.sh`'s rsync + the Dockerfile's `COPY priv priv` bake it into
  the image like any other `priv/` asset. Pass an explicit path to load a
  different file instead.
  """
  def import_questions_json(path \\ nil) do
    load_app()
    path = path || Application.app_dir(:nurseprep, "priv/source_data/nursing_questions.json")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(NursePrep.Repo, fn _repo ->
        NursePrep.Questions.Import.run(path)
      end)

    IO.puts(
      "created: #{result.created}, skipped_existing: #{result.skipped_existing}, errored: #{result.errored}"
    )

    result
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
