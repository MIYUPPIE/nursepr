defmodule NursePrep.Repo.Migrations.AddWhatsappLidToUsers do
  use Ecto.Migration

  # WhatsApp's newer privacy-ID system (`<id>@lid`) hides a contact's real
  # phone number from Evolution/Baileys entirely - there's no reliable way
  # to derive one from the other (see `Whatsapp.Session.route_lid_confirmation/2`).
  # This remembers the mapping once a student confirms their phone number
  # once, so every message after that resolves without asking again.
  def change do
    alter table(:users) do
      add :whatsapp_lid, :string
    end

    create unique_index(:users, [:whatsapp_lid])
  end
end
