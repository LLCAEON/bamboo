defmodule Bamboo.MailgunAdapter do
  @moduledoc """
  Sends email using Mailgun's API.

  Use this adapter to send emails through Mailgun's API. Requires that an API
  key and a domain are set in the config.

  ## Example config

      # In config/config.exs, or config.prod.exs, etc.
      config :my_app, MyApp.Mailer,
        adapter: Bamboo.MailgunAdapter,
        api_key: "my_api_key" # or {:system, "MAILGUN_API_KEY"},
        domain: "your.domain" # or {:system, "MAILGUN_DOMAIN"}

      # Define a Mailer. Maybe in lib/my_app/mailer.ex
      defmodule MyApp.Mailer do
        use Bamboo.Mailer, otp_app: :my_app
      end
  """

  @service_name "Mailgun"
  @base_uri "https://api.mailgun.net/v3/"
  @behaviour Bamboo.Adapter

  alias Bamboo.Email
  import Bamboo.ApiError

  def deliver(email, config) do
    body = email |> to_mailgun_body |> Plug.Conn.Query.encode
    config = handle_config(config)

    case :hackney.post(full_uri(config), headers(config), body, [:with_body]) do
      {:ok, status, _headers, response} when status > 299 ->
        raise_api_error(@service_name, response, body)
      {:ok, status, headers, response} ->
        %{status_code: status, headers: headers, body: response}
      {:error, reason} ->
        raise_api_error(inspect(reason))
    end
  end

  @doc false
  def handle_config(config) do
    config
    |> Map.put(:api_key, get_setting(config, :api_key))
    |> Map.put(:domain, get_setting(config, :domain))
  end

  defp get_setting(config, key) do
    config[key]
    |> case do
      {:system, var} ->
        System.get_env(var)

      value ->
        value
    end
    |> case do
      value when value in [nil, ""] ->
        raise_missing_setting_error(config, key)

      value ->
        value
    end
  end

  defp raise_missing_setting_error(config, setting) do
    raise ArgumentError, """
    There was no #{setting} set for the Mailgun adapter.

    * Here are the config options that were passed in:

    #{inspect config}
    """
  end

  defp headers(config) do
    [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Authorization", "Basic #{auth_token(config)}"},
    ]
  end

  defp auth_token(config) do
    Base.encode64("api:" <> config.api_key)
  end

  defp to_mailgun_body(%Email{} = email) do
    email
    |> Map.from_struct
    |> combine_name_and_email
    |> put_html_body(email)
    |> put_text_body(email)
    |> put_headers(email)
    |> put_custom_vars(email)
    |> filter_non_empty_mailgun_fields
  end

  defp combine_name_and_email(map) when is_map(map) do
    Enum.reduce([:from, :to, :cc, :bcc], map, fn key, acc ->
      Map.put(acc, key, combine_name_and_email(map[key]))
    end)
  end

  defp combine_name_and_email(list) when is_list(list) do
    Enum.map(list, &combine_name_and_email/1)
  end

  defp combine_name_and_email(tuple) when is_tuple(tuple) do
    case tuple do
      {nil, email} -> email
      {name, email} -> "#{name} <#{email}>"
    end
  end

  defp put_html_body(body, %Email{html_body: html_body}), do: Map.put(body, :html, html_body)

  defp put_text_body(body, %Email{text_body: text_body}), do: Map.put(body, :text, text_body)

  defp put_headers(body, %Email{headers: headers}) do
    Enum.reduce(headers, body, fn({key, value}, acc) ->
      Map.put(acc, :"h:#{key}", value)
    end)
  end

  defp put_custom_vars(body, %Email{private: private}) do
    custom_vars = Map.get(private, :mailgun_custom_vars, %{})

    Enum.reduce(custom_vars, body, fn({key, value}, acc) ->
      Map.put(acc, :"v:#{key}", value)
    end)
  end

  @mailgun_message_fields ~w(from to cc bcc subject text html)a

  def filter_non_empty_mailgun_fields(map) do
    Enum.filter(map, fn({key, value}) ->
      # Key is a well known mailgun field or is an header or custom var field and its value is not empty
      (key in @mailgun_message_fields || String.starts_with?(Atom.to_string(key), ["h:", "v:"])) && !(value in [nil, "", []])
    end)
  end

  defp full_uri(config) do
    Application.get_env(:bamboo, :mailgun_base_uri, @base_uri)
    <> config.domain <> "/messages"
  end
end
