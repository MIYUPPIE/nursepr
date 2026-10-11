defmodule NursePrep.Accounts.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "profiles" do
    field :full_name, :string
    field :target_exam_date, :date
    field :school, :string
    field :whatsapp_opt_in, :boolean, default: true
    field :leaderboard_opt_in, :boolean, default: true
    field :timezone, :string, default: "Africa/Lagos"

    belongs_to :user, NursePrep.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :user_id,
      :full_name,
      :target_exam_date,
      :school,
      :whatsapp_opt_in,
      :leaderboard_opt_in,
      :timezone
    ])
    |> validate_required([:user_id, :full_name])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end
end
