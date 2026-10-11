defmodule NursePrep.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(student admin reviewer)

  def roles, do: @roles

  schema "users" do
    field :phone, :string
    field :email, :string
    field :whatsapp_lid, :string
    field :telegram_chat_id, :integer
    field :role, :string, default: "student"
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    has_one :profile, NursePrep.Accounts.Profile

    timestamps(type: :utc_datetime)
  end

  @doc "The identifier that actually reaches this user: phone (WhatsApp) or email."
  def identifier(%__MODULE__{phone: phone, email: email}), do: phone || email

  @doc """
  A user changeset for registering or changing the phone number.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the phone, useful when displaying live validations.
      Defaults to `true`.
  """
  def phone_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:phone])
    |> validate_phone(opts)
  end

  defp validate_phone(changeset, opts) do
    changeset = validate_required(changeset, [:phone])

    changeset =
      case get_change(changeset, :phone) do
        nil ->
          changeset

        phone ->
          case NursePrep.Accounts.PhoneNumber.normalize(phone) do
            {:ok, normalized} -> put_change(changeset, :phone, normalized)
            {:error, message} -> add_error(changeset, :phone, message)
          end
      end

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:phone, NursePrep.Repo)
      |> unique_constraint(:phone)
    else
      changeset
    end
  end

  @doc """
  A user changeset for registering or changing the email address-the
  login path for students who don't have WhatsApp.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset = validate_required(changeset, [:email])

    changeset =
      case get_change(changeset, :email) do
        nil ->
          changeset

        email ->
          case NursePrep.Accounts.Email.normalize(email) do
            {:ok, normalized} -> put_change(changeset, :email, normalized)
            {:error, message} -> add_error(changeset, :email, message)
          end
      end

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, NursePrep.Repo)
      |> unique_constraint(:email)
    else
      changeset
    end
  end

  @doc """
  A changeset linking a WhatsApp `@lid` identity (see
  `NursePrep.Whatsapp.Session.route_lid_confirmation/2`) to this user, once
  they've confirmed it's really them by replying with their account's phone
  number. Unlike `phone_changeset`/`email_changeset`, `whatsapp_lid` isn't
  user-facing data to validate the *format* of-it's an opaque WhatsApp
  identifier, only its uniqueness matters.
  """
  def whatsapp_lid_changeset(user, attrs) do
    user
    |> cast(attrs, [:whatsapp_lid])
    |> validate_required([:whatsapp_lid])
    |> unsafe_validate_unique(:whatsapp_lid, NursePrep.Repo)
    |> unique_constraint(:whatsapp_lid)
  end

  @doc """
  A changeset linking a Telegram chat id (see
  `NursePrep.Whatsapp.Session.route_telegram_confirmation/2`) to this user,
  once they've confirmed it's really them by replying with their account's
  phone number or email. Same treatment as `whatsapp_lid_changeset/2`-an
  opaque numeric id, only its uniqueness matters.
  """
  def telegram_chat_id_changeset(user, attrs) do
    user
    |> cast(attrs, [:telegram_chat_id])
    |> validate_required([:telegram_chat_id])
    |> unsafe_validate_unique(:telegram_chat_id, NursePrep.Repo)
    |> unique_constraint(:telegram_chat_id)
  end

  @doc "A changeset for admin-driven role changes."
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end
end
