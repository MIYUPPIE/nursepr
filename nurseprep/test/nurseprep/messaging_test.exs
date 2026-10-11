defmodule NursePrep.MessagingTest do
  use ExUnit.Case, async: true

  import Mox

  alias NursePrep.Messaging

  setup :verify_on_exit!

  describe "telegram?/1" do
    test "true for a tagged Telegram identity" do
      assert Messaging.telegram?("telegram:123456789")
    end

    test "false for a bare phone number" do
      refute Messaging.telegram?("+2348012345678")
    end

    test "false for a WhatsApp @lid identity" do
      refute Messaging.telegram?("123456789@lid")
    end
  end

  describe "whatsapp_lid?/1" do
    test "true for an @lid identity" do
      assert Messaging.whatsapp_lid?("123456789@lid")
    end

    test "false for a bare phone number or a Telegram identity" do
      refute Messaging.whatsapp_lid?("+2348012345678")
      refute Messaging.whatsapp_lid?("telegram:123456789")
    end
  end

  describe "tag_telegram/1 and telegram_chat_id/1" do
    test "round-trip a chat id through the tagged identity" do
      identity = Messaging.tag_telegram(123_456_789)
      assert identity == "telegram:123456789"
      assert Messaging.telegram_chat_id(identity) == 123_456_789
    end
  end

  describe "send_text/2" do
    test "dispatches to the Telegram client for a tagged Telegram identity" do
      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn 123_456_789, "hi" ->
        {:ok, %{}}
      end)

      assert {:ok, %{}} = Messaging.send_text("telegram:123456789", "hi")
    end

    test "dispatches to the Evolution client for a bare phone number" do
      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn "+2348012345678", "hi" ->
        {:ok, %{}}
      end)

      assert {:ok, %{}} = Messaging.send_text("+2348012345678", "hi")
    end

    test "dispatches to the Evolution client for a WhatsApp @lid identity" do
      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn "123456789@lid", "hi" ->
        {:ok, %{}}
      end)

      assert {:ok, %{}} = Messaging.send_text("123456789@lid", "hi")
    end
  end
end
