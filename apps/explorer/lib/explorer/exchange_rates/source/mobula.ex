defmodule Explorer.ExchangeRates.Source.Mobula do
  @moduledoc """
  Adapter for fetching exchange rates from https://mobula.io
  """

  require Logger
  alias Explorer.Chain
  alias Explorer.ExchangeRates.{Source, Token}

  import Source, only: [to_decimal: 1]

  @behaviour Source

  @impl Source
  def format_data(%{"data" => %{"market_cap" => _} = market_data}) do
    current_price = market_data["price"]
    image_url = market_data["logo"]
    id = market_data["symbol"]

    btc_value =
      if Application.get_env(:explorer, Explorer.ExchangeRates)[:fetch_btc_value], do: get_btc_value(id, market_data)

    [
      %Token{
        available_supply: to_decimal(market_data["circulating_supply"]),
        total_supply: to_decimal(market_data["total_supply"]) || to_decimal(market_data["circulating_supply"]),
        btc_value: to_decimal(btc_value),
        id: id,
        last_updated: nil,
        market_cap_usd: to_decimal(market_data["market_cap"]),
        tvl_usd: nil,
        name: market_data["name"],
        symbol: String.upcase(market_data["symbol"]),
        usd_value: to_decimal(current_price),
        volume_24h_usd: to_decimal(market_data["volume"]),
        image_url: image_url
      }
    ]
  end

  @impl Source
  def format_data(%{"data" => data}) when is_list(data) and length(data) >= 1000 do
    chain = chain()

    Enum.reduce(data, [], fn item, acc ->
      case item do
        %{"blockchains" => blockchains, "contracts" => contracts}
        when is_list(blockchains) and is_list(contracts) ->
          with {:ok, index} <- find_contract_index(blockchains, chain),
               {:ok, contract} <- get_contract(contracts, index),
               {:ok, token_contract_hash} <- cast_contract_hash(contract) do
            [token_contract_hash | acc]
          else
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  @impl Source
  def format_data(%{"data" => data}) do
    data
    |> Enum.reduce(%{}, fn
      {address_hash_string, market_data}, acc ->
        case Explorer.Chain.Hash.Address.cast(address_hash_string) do
          {:ok, address_hash} ->
            acc
            |> Map.put(address_hash, %{
              fiat_value: Map.get(market_data, "price"),
              circulating_market_cap: Map.get(market_data, "market_cap"),
              volume_24h: Map.get(market_data, "volume")
            })

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  @impl Source
  def format_data(_), do: []

  defp find_contract_index(blockchains, chain) do
    case Enum.find_index(blockchains, fn bc -> bc == chain end) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp get_contract(contracts, index) do
    contract = Enum.at(contracts, index)

    if contract do
      {:ok, contract}
    else
      :error
    end
  end

  defp cast_contract_hash(contract) do
    case Chain.Hash.Address.cast(contract) do
      {:ok, token_contract_hash} -> {:ok, token_contract_hash}
      _ -> :error
    end
  end

  @impl Source
  def source_url do
    coin_id = config(:coin_id)
    symbol = if Explorer.coin(), do: String.upcase(Explorer.coin()), else: nil

    cond do
      coin_id ->
        "#{base_url()}/market/data?asset=#{coin_id}"

      symbol ->
        "#{base_url()}/market/data?symbol=#{symbol}"

      true ->
        nil
    end
  end

  @impl Source
  def source_url(token_addresses) when is_list(token_addresses) do
    joined_addresses = token_addresses |> Enum.map_join(",", &to_string/1)

    "#{base_url()}/market/multi-data?blockchains=#{chain()}&assets=#{joined_addresses}"
  end

  @impl Source
  def source_url(:coins_list) do
    "#{base_url()}/all?fields=contracts,blockchains"
  end

  @impl Source
  def source_url(input) do
    symbol = input
    "#{base_url()}/market/data?symbol=#{symbol}"
  end

  @spec secondary_history_source_url() :: String.t()
  def secondary_history_source_url do
    id = config(:secondary_coin_id)

    if id, do: "#{base_url()}/market/history?asset=#{id}", else: nil
  end

  @spec history_source_url() :: String.t()
  def history_source_url do
    coin_id = config(:coin_id)
    symbol = if Explorer.coin(), do: String.upcase(Explorer.coin()), else: nil

    cond do
      coin_id ->
        "#{base_url()}/market/history?asset=#{coin_id}"

      symbol ->
        "#{base_url()}/market/history?symbol=#{symbol}"

      true ->
        nil
    end
  end

  @spec history_url(non_neg_integer(), boolean()) :: String.t()
  def history_url(previous_days, secondary_coin?) do
    now = DateTime.utc_now()
    date_days_ago = DateTime.add(now, -previous_days, :day)
    timestamp_ms = DateTime.to_unix(date_days_ago) * 1000

    source_url = if secondary_coin?, do: secondary_history_source_url(), else: history_source_url()

    "#{source_url}&from=#{timestamp_ms}"
  end

  @spec market_cap_history_url(non_neg_integer()) :: String.t()
  def market_cap_history_url(previous_days) do
    now = DateTime.utc_now()
    date_days_ago = DateTime.add(now, -previous_days, :day)
    timestamp_ms = DateTime.to_unix(date_days_ago) * 1000

    "#{history_source_url()}&from=#{timestamp_ms}&period=5"
  end

  @impl Source
  def headers do
    if config(:api_key) do
      [{"Authorization", "#{config(:api_key)}"}]
    else
      []
    end
  end

  defp get_current_price(market_data) do
    if market_data["price"] do
      to_decimal(market_data["price"])
    else
      1
    end
  end

  defp get_btc_value(id, market_data) do
    case get_btc_price() do
      {:ok, price} ->
        btc_price = to_decimal(price)
        current_price = get_current_price(market_data)

        if id != "btc" && current_price && btc_price do
          Decimal.div(current_price, btc_price)
        else
          1
        end

      _ ->
        1
    end
  end

  defp chain do
    config(:platform) || "ethereum"
  end

  defp base_url do
    config(:base_url)
  end

  defp get_btc_price do
    url = "#{base_url()}/market/data?asset=Bitcoin"

    case Source.http_request(url, headers()) do
      {:ok, %{"price" => current_price}} ->
        {:ok, current_price}

      resp ->
        resp
    end
  end

  @spec config(atom()) :: term
  defp config(key) do
    Application.get_env(:explorer, __MODULE__, [])[key]
  end
end
