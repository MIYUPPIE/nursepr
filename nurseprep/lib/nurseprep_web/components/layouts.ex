defmodule NursePrepWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use NursePrepWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the current auth scope"
  attr :max_w, :string, default: "max-w-2xl", doc: "max-width utility class for the content well"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300">
      <div class="flex-1">
        <a href="/" class="flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">NursePrep</span>
        </a>
      </div>
      <div class="flex-none">
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class={["mx-auto", @max_w]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Admin shell: a persistent sidebar nav + content area, used by every
  `NursePrepWeb.Admin.*` LiveView instead of the public marketing layout.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active, :atom, default: nil, doc: "which nav item to highlight"
  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="admin-drawer" type="checkbox" class="drawer-toggle" />
      <div class="drawer-content flex flex-col">
        <div class="navbar bg-base-100 border-b border-base-300 px-4 lg:hidden">
          <label for="admin-drawer" class="btn btn-ghost btn-square">
            <.icon name="hero-bars-3" class="size-6" />
          </label>
          <img src={~p"/images/logo.svg"} width="24" height="24" class="ml-2" />
          <span class="ml-2 font-semibold">NursePrep Admin</span>
          <div class="flex-1" />
          <.theme_toggle />
        </div>
        <main class="flex-1 p-4 sm:p-6 lg:p-8">
          <.flash_group flash={@flash} />
          {render_slot(@inner_block)}
        </main>
      </div>
      <div class="drawer-side z-20">
        <label for="admin-drawer" aria-label="close sidebar" class="drawer-overlay"></label>
        <aside class="min-h-full w-64 bg-base-200 flex flex-col">
          <div class="p-4">
            <a href="/admin" class="flex items-center gap-2">
              <img src={~p"/images/logo.svg"} width="28" height="28" />
              <span>
                <span class="block text-lg font-bold leading-tight">NursePrep</span>
                <span class="block text-xs font-medium text-primary leading-tight">Admin</span>
              </span>
            </a>
          </div>
          <ul class="menu flex-1 px-2">
            <li>
              <.admin_nav_link
                navigate={~p"/admin"}
                active={@active == :dashboard}
                icon="hero-squares-2x2"
              >
                Dashboard
              </.admin_nav_link>
            </li>
            <li>
              <.admin_nav_link
                navigate={~p"/admin/review-queue"}
                active={@active == :review_queue}
                icon="hero-inbox-stack"
              >
                Review queue
              </.admin_nav_link>
            </li>
            <li>
              <.admin_nav_link
                navigate={~p"/admin/questions"}
                active={@active == :questions}
                icon="hero-question-mark-circle"
              >
                Questions
              </.admin_nav_link>
            </li>
            <li>
              <.admin_nav_link
                navigate={~p"/admin/subjects"}
                active={@active == :subjects}
                icon="hero-book-open"
              >
                Subjects
              </.admin_nav_link>
            </li>
            <li>
              <.admin_nav_link
                navigate={~p"/admin/ingestion"}
                active={@active == :ingestion}
                icon="hero-arrow-up-tray"
              >
                Ingestion
              </.admin_nav_link>
            </li>
            <li :if={@current_scope && @current_scope.user.role == "admin"} class="menu-title mt-2">
              Admin only
            </li>
            <li :if={@current_scope && @current_scope.user.role == "admin"}>
              <.admin_nav_link
                navigate={~p"/admin/users"}
                active={@active == :users}
                icon="hero-users"
              >
                Users
              </.admin_nav_link>
            </li>
            <li :if={@current_scope && @current_scope.user.role == "admin"}>
              <.admin_nav_link
                navigate={~p"/admin/subscriptions"}
                active={@active == :subscriptions}
                icon="hero-banknotes"
              >
                Subscriptions
              </.admin_nav_link>
            </li>
            <li :if={@current_scope && @current_scope.user.role == "admin"} class="menu-title mt-2">
              Ops
            </li>
            <li :if={@current_scope && @current_scope.user.role == "admin"}>
              <a href="/admin/oban" class="flex items-center gap-2">
                <.icon name="hero-cog-6-tooth" class="size-5" /> Jobs
              </a>
            </li>
          </ul>
          <div class="p-4 border-t border-base-300 text-sm">
            <div class="flex items-center justify-between mb-3">
              <p class="truncate">
                {@current_scope && NursePrep.Accounts.User.identifier(@current_scope.user)}
              </p>
              <.theme_toggle />
            </div>
            <div class="flex gap-2">
              <.link navigate={~p"/"} class="link link-hover">Student app</.link>
              <.link href={~p"/users/log-out"} method="delete" class="link link-hover">Log out</.link>
            </div>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp admin_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2",
        @active && "bg-primary/10 text-primary font-semibold"
      ]}
    >
      <.icon name={@icon} class="size-5" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Student app shell: a persistent left sidebar + topbar on desktop,
  collapsing to a top bar + bottom tab bar on mobile-used by every
  student-facing LiveView instead of the Phoenix marketing layout.

  The `:notifications` slot is optional and dashboard-only: the bell in
  the topbar always renders, but only `DashboardLive` has the live-computed
  insight data to fill its dropdown, since that's the one page that already
  fetches everything the insights are derived from. Every other page's
  bell just links to `/dashboard`.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active, :atom, default: nil

  attr :container_class, :string,
    default: "max-w-4xl",
    doc: "widen for pages (like the AI tutor) that need more than the default reading width"

  slot :inner_block, required: true
  slot :notifications

  def student(assigns) do
    ~H"""
    <div class="min-h-screen md:flex bg-base-200/40">
      <aside class="hidden md:flex md:flex-col md:w-56 lg:w-64 md:shrink-0 md:sticky md:top-0 md:h-screen bg-base-100 border-r border-base-300">
        <div class="p-5">
          <.link navigate={~p"/dashboard"} class="flex items-center gap-2">
            <img src={~p"/images/logo.svg"} width="30" height="30" />
            <span class="text-lg font-bold">NursePrep</span>
          </.link>
        </div>

        <nav class="flex-1 overflow-y-auto px-3 space-y-5 pb-4" aria-label="Primary">
          <div :for={{section, items} <- student_nav_sections()}>
            <p class="px-3 text-[11px] font-semibold uppercase tracking-wider text-base-content/40 mb-1">
              {section}
            </p>
            <ul class="space-y-0.5">
              <li :for={{path, label, key, icon} <- items}>
                <.sidebar_link navigate={path} icon={icon} active={@active == key}>{label}</.sidebar_link>
              </li>
            </ul>
          </div>
        </nav>

        <div class="p-3 border-t border-base-300 space-y-0.5">
          <.sidebar_link
            :if={@current_scope && NursePrep.Accounts.admin?(@current_scope.user)}
            navigate={~p"/admin"}
            icon="hero-shield-check"
            active={false}
          >
            Admin
          </.sidebar_link>
          <.sidebar_link
            navigate={~p"/subscription"}
            icon="hero-banknotes"
            active={@active == :subscription}
          >
            Subscription
          </.sidebar_link>
          <.sidebar_link
            navigate={~p"/users/settings"}
            icon="hero-cog-6-tooth"
            active={@active == :settings}
          >
            Settings
          </.sidebar_link>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="flex items-center gap-2.5 px-3 py-2 rounded-xl text-sm font-medium text-base-content/60 hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-4.5" /> Log out
          </.link>
        </div>
      </aside>

      <div class="flex-1 flex flex-col min-w-0 pb-[calc(4rem+env(safe-area-inset-bottom))] md:pb-0">
        <header class="sticky top-0 z-30 bg-base-100/80 backdrop-blur border-b border-base-300 px-4 sm:px-6 lg:px-8 h-16 flex items-center gap-2 sm:gap-3">
          <.link
            navigate={~p"/dashboard"}
            class="md:hidden flex items-center gap-2 font-bold shrink-0"
          >
            <img src={~p"/images/logo.svg"} width="26" height="26" />
          </.link>

          <div
            class="dropdown hidden sm:block flex-1 max-w-xs"
            id="nav-quick-jump"
            phx-hook="NavSearch"
          >
            <label class="input input-sm w-full flex items-center gap-2 rounded-full bg-base-200 border-none">
              <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
              <input
                type="text"
                placeholder="Quick jump..."
                class="grow bg-transparent focus:outline-none"
                data-quick-jump-input
                autocomplete="off"
                aria-label="Quick jump to a page"
              />
            </label>
            <ul
              tabindex="0"
              class="dropdown-content menu z-40 mt-1.5 w-full max-h-72 flex-nowrap overflow-y-auto rounded-box bg-base-100 border border-base-300 shadow-lg p-1"
            >
              <li
                :for={{path, label, _key, icon} <- student_flat_nav_items()}
                data-quick-jump-item
                data-quick-jump-label={label}
              >
                <.link navigate={path} class="flex items-center gap-2">
                  <.icon name={icon} class="size-4 opacity-60" /> {label}
                </.link>
              </li>
            </ul>
          </div>

          <div class="flex-1 sm:hidden" />

          <div class="flex-none hidden sm:block">
            <.theme_toggle />
          </div>

          <div class="dropdown dropdown-end flex-none">
            <button
              type="button"
              tabindex="0"
              class="btn btn-ghost btn-square"
              aria-label="Notifications"
            >
              <.icon name="hero-bell" class="size-5" />
            </button>
            <div
              tabindex="0"
              class="dropdown-content z-40 mt-3 w-80 max-w-[90vw] rounded-box bg-base-100 border border-base-300 p-3 shadow-lg"
            >
              <p class="text-sm font-semibold px-1 mb-2">Notifications</p>
              <%= if @notifications != [] do %>
                {render_slot(@notifications)}
              <% else %>
                <.link navigate={~p"/dashboard"} class="block text-sm text-base-content/60 px-1 py-2">
                  See what's new on your dashboard.
                </.link>
              <% end %>
            </div>
          </div>

          <div class="dropdown dropdown-end flex-none">
            <button
              type="button"
              tabindex="0"
              class="btn btn-ghost btn-circle"
              aria-label="Account menu"
            >
              <span class="flex size-9 items-center justify-center rounded-full bg-primary/10 text-primary">
                <.icon name="hero-user-circle" class="size-5" />
              </span>
            </button>
            <ul
              tabindex="0"
              class="menu dropdown-content z-40 mt-3 w-52 rounded-box bg-base-100 border border-base-300 p-2 shadow-lg"
            >
              <.account_menu_items current_scope={@current_scope} />
            </ul>
          </div>
        </header>

        <main class="flex-1 flex flex-col px-4 py-6 sm:px-6 lg:px-8 min-h-0">
          <div class={["mx-auto w-full flex-1 flex flex-col min-h-0", @container_class]}>
            <.flash_group flash={@flash} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <nav class="dock md:hidden z-30" aria-label="Primary">
        <.link
          :for={{path, label, key, icon} <- student_bottom_nav_items()}
          navigate={path}
          class={@active == key && "dock-active text-primary"}
        >
          <.icon name={icon} class="size-5" />
          <span class="dock-label">{label}</span>
        </.link>
        <button
          type="button"
          phx-click={JS.toggle(to: "#mobile-more-menu") |> JS.toggle(to: "#mobile-more-backdrop")}
          class={
            Enum.any?(student_more_nav_items(), fn {_p, _l, key, _i} -> @active == key end) &&
              "dock-active text-primary"
          }
        >
          <.icon name="hero-bars-3" class="size-5" />
          <span class="dock-label">More</span>
        </button>
      </nav>

      <div
        id="mobile-more-backdrop"
        class="hidden md:hidden fixed inset-0 bg-black/20 z-30"
        phx-click={JS.toggle(to: "#mobile-more-menu") |> JS.toggle(to: "#mobile-more-backdrop")}
      >
      </div>
      <div
        id="mobile-more-menu"
        class="hidden md:hidden fixed inset-x-3 bottom-[calc(4rem+env(safe-area-inset-bottom)+0.75rem)] z-40 rounded-2xl bg-base-100 border border-base-300 shadow-lg p-2"
      >
        <ul class="menu">
          <li :for={{path, label, _key, icon} <- student_more_nav_visible_items()}>
            <.link navigate={path} class="flex items-center gap-2.5">
              <.icon name={icon} class="size-4.5" /> {label}
            </.link>
          </li>
          <li class="my-1"><hr class="border-base-300" /></li>
          <.account_menu_items current_scope={@current_scope} />
        </ul>
      </div>
    </div>
    """
  end

  # {path, label, active_key, icon} grouped under a section header for the
  # desktop sidebar. Only real, routable destinations appear here-features
  # the brief asks for with no backend yet (bookmarks, a question-bank
  # browser distinct from practice, gamified achievements, ...) are simply
  # not represented rather than linking to something that doesn't exist.
  defp student_nav_sections do
    [
      {"Overview", [{~p"/dashboard", "Dashboard", :dashboard, "hero-squares-2x2"}]},
      {"Practice", [{~p"/practice", "Practice", :practice, "hero-pencil-square"}]},
      {"Exams", [{~p"/exam/new", "Mock Exam", :exam, "hero-clock"}]},
      {"Learning", [{~p"/tutor", "Tutor", :tutor, "hero-sparkles"}]},
      {"Performance", [{~p"/analytics", "Analytics", :analytics, "hero-chart-bar"}]},
      {"Community", [{~p"/leaderboard", "Leaderboard", :leaderboard, "hero-trophy"}]}
    ]
  end

  defp student_flat_nav_items do
    Enum.flat_map(student_nav_sections(), fn {_section, items} -> items end)
  end

  # The 4 highest-traffic destinations, pinned to the mobile bottom tab bar.
  defp student_bottom_nav_items do
    [
      {~p"/dashboard", "Home", :dashboard, "hero-home"},
      {~p"/practice", "Practice", :practice, "hero-pencil-square"},
      {~p"/exam/new", "Exams", :exam, "hero-clock"},
      {~p"/analytics", "Progress", :analytics, "hero-chart-bar"}
    ]
  end

  # Routes that live behind the bottom bar's "More" tab-drives whether that
  # tab itself shows as active. `:subscription` is included here (so
  # landing on that page still highlights "More") but rendered only once,
  # via `account_menu_items/1` further down the same sheet, rather than
  # listed again in `student_more_nav_visible_items/0` below.
  defp student_more_nav_items do
    [
      {~p"/tutor", "Tutor", :tutor, "hero-sparkles"},
      {~p"/leaderboard", "Leaderboard", :leaderboard, "hero-trophy"},
      {~p"/subscription", "Subscription", :subscription, "hero-banknotes"}
    ]
  end

  # The subset of `student_more_nav_items/0` actually rendered as links at
  # the top of the "More" sheet-excludes `:subscription`, which already
  # appears in the account-menu section immediately below it.
  defp student_more_nav_visible_items do
    Enum.reject(student_more_nav_items(), fn {_path, _label, key, _icon} ->
      key == :subscription
    end)
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2.5 px-3 py-2 rounded-xl text-sm font-medium transition-colors",
        (@active && "bg-primary/10 text-primary") ||
          "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
      aria-current={@active && "page"}
    >
      <.icon name={@icon} class="size-4.5" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :current_scope, :map, default: nil

  defp account_menu_items(assigns) do
    ~H"""
    <li>
      <.link navigate={~p"/users/settings"} class="flex items-center gap-2.5">
        <.icon name="hero-cog-6-tooth" class="size-4.5 opacity-60" /> Settings
      </.link>
    </li>
    <li>
      <.link navigate={~p"/subscription"} class="flex items-center gap-2.5">
        <.icon name="hero-banknotes" class="size-4.5 opacity-60" /> Subscription
      </.link>
    </li>
    <li :if={@current_scope && NursePrep.Accounts.admin?(@current_scope.user)}>
      <.link navigate={~p"/admin"} class="flex items-center gap-2.5">
        <.icon name="hero-shield-check" class="size-4.5 opacity-60" /> Admin
      </.link>
    </li>
    <li>
      <.link href={~p"/users/log-out"} method="delete" class="flex items-center gap-2.5">
        <.icon name="hero-arrow-right-on-rectangle" class="size-4.5 opacity-60" /> Log out
      </.link>
    </li>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
