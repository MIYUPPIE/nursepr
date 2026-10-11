defmodule NursePrep.Repo do
  use Ecto.Repo,
    otp_app: :nurseprep,
    adapter: Ecto.Adapters.Postgres
end
