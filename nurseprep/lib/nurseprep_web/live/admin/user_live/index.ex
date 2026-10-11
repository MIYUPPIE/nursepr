defmodule NursePrepWeb.Admin.UserLive.Index do
  @moduledoc """
  Search/filter and role management-admin-only (a `reviewer` has no
  business seeing phone numbers or subscription status at a glance, so
  this route is gated by `:require_strict_admin`, not the looser
  `:require_admin` every other `/admin` page uses).
  """
  use NursePrepWeb, :live_view

  alias NursePrep.{Accounts, Subscriptions}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:users}>
      <.header icon="hero-users">
        Users
        <:subtitle>{length(@users)} matching · role changes take effect immediately</:subtitle>
      </.header>

      <div class="flex flex-wrap gap-2 my-4 items-center">
        <form id="user-search-form" phx-change="search" class="flex-1 min-w-48">
          <label class="input input-bordered input-sm w-full flex items-center gap-2">
            <.icon name="hero-magnifying-glass" class="size-4 text-base-content/40" />
            <input
              type="text"
              name="search"
              value={@search}
              placeholder="Search by phone or email…"
              class="grow"
            />
          </label>
        </form>
        <button
          :for={role <- ["student", "admin", "reviewer"]}
          phx-click="filter_role"
          phx-value-role={role}
          class={["btn btn-sm", @role == role && "btn-primary"]}
        >
          {String.capitalize(role)}
        </button>
        <button
          phx-click="filter_role"
          phx-value-role=""
          class={["btn btn-sm", @role == nil && "btn-primary"]}
        >
          All
        </button>
      </div>

      <.table id="users" rows={@users}>
        <:col :let={u} label="Phone">
          <form id={"phone-form-#{u.id}"} phx-change="change_phone" phx-value-user_id={u.id}>
            <input
              type="text"
              name="phone"
              value={u.phone}
              phx-debounce="blur"
              placeholder="—"
              class="input input-bordered input-xs w-36"
            />
          </form>
        </:col>
        <:col :let={u} label="Email">
          <form id={"email-form-#{u.id}"} phx-change="change_email" phx-value-user_id={u.id}>
            <input
              type="text"
              name="email"
              value={u.email}
              phx-debounce="blur"
              placeholder="—"
              class="input input-bordered input-xs w-44"
            />
          </form>
        </:col>
        <:col :let={u} label="Name">{(u.profile && u.profile.full_name) || "—"}</:col>
        <:col :let={u} label="Role">
          <form id={"role-form-#{u.id}"} phx-change="change_role" phx-value-user_id={u.id}>
            <select name="role" class="select select-bordered select-xs">
              <option :for={r <- ~w(student admin reviewer)} value={r} selected={r == u.role}>
                {String.capitalize(r)}
              </option>
            </select>
          </form>
        </:col>
        <:col :let={u} label="Confirmed">
          <.icon
            name={if u.confirmed_at, do: "hero-check-circle", else: "hero-x-circle"}
            class={["size-5", if(u.confirmed_at, do: "text-success", else: "text-base-content/40")]}
          />
        </:col>
        <:col :let={u} label="Subscription">
          <span class={["badge badge-sm", subscription_badge(u.id, @active_subscriptions)]}>
            {if u.id in @active_subscriptions, do: "Active", else: "Free"}
          </span>
        </:col>
        <:col :let={u} label="Joined">{Calendar.strftime(u.inserted_at, "%Y-%m-%d")}</:col>
        <:col :let={u} label="">
          <button
            :if={u.id != @current_scope.user.id}
            phx-click="delete_user"
            phx-value-user_id={u.id}
            data-confirm={"Permanently delete #{NursePrep.Accounts.User.identifier(u)}? This deletes their profile, quiz history, subscriptions, and cannot be undone."}
            class="link link-error text-sm"
          >
            Delete
          </button>
        </:col>
      </.table>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(search: "", role: nil) |> load_users()}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(search: search) |> load_users()}
  end

  def handle_event("filter_role", %{"role" => role}, socket) do
    role = if role == "", do: nil, else: role
    {:noreply, socket |> assign(role: role) |> load_users()}
  end

  def handle_event("change_role", %{"user_id" => user_id, "role" => role}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(user_id)))
    {:ok, _} = Accounts.promote_to_role(user, role)

    {:noreply,
     socket
     |> load_users()
     |> put_flash(:info, "#{NursePrep.Accounts.User.identifier(user)} is now #{role}.")}
  end

  def handle_event("change_phone", %{"user_id" => user_id, "phone" => phone}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(user_id)))

    case Accounts.update_user_phone(user, phone) do
      {:ok, _updated} ->
        {:noreply, socket |> load_users() |> put_flash(:info, "Phone updated.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error(changeset, :phone))}
    end
  end

  def handle_event("change_email", %{"user_id" => user_id, "email" => email}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(user_id)))

    case Accounts.update_user_email(user, email) do
      {:ok, _updated} ->
        {:noreply, socket |> load_users() |> put_flash(:info, "Email updated.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error(changeset, :email))}
    end
  end

  def handle_event("delete_user", %{"user_id" => user_id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(user_id)))
    identifier = NursePrep.Accounts.User.identifier(user)

    case Accounts.delete_user(user) do
      {:ok, _deleted} ->
        {:noreply, socket |> load_users() |> put_flash(:info, "#{identifier} deleted.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete #{identifier}.")}
    end
  end

  defp changeset_error(changeset, field) do
    case NursePrepWeb.CoreComponents.translate_errors(changeset.errors, field) do
      [] -> "That value isn't valid."
      messages -> "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}"
    end
  end

  defp load_users(socket) do
    filters =
      %{}
      |> maybe_put(:search, blank_to_nil(socket.assigns.search))
      |> maybe_put(:role, socket.assigns.role)

    users = Accounts.list_users(filters)
    active_subscriptions = users |> Enum.filter(&Subscriptions.active?/1) |> MapSet.new(& &1.id)

    assign(socket, users: users, active_subscriptions: active_subscriptions)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp subscription_badge(user_id, active_subscriptions) do
    if MapSet.member?(active_subscriptions, user_id), do: "badge-success", else: "badge-ghost"
  end
end
