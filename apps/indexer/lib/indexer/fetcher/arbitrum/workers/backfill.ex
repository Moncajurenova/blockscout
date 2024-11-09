defmodule Indexer.Fetcher.Arbitrum.Workers.Backfill do
  @moduledoc """
    Worker for backfilling missing Arbitrum-specific fields in blocks and transactions.
  """
  import Ecto.Query
  import Indexer.Fetcher.Arbitrum.Utils.Logging, only: [log_warning: 1, log_debug: 1, log_info: 1]

  alias EthereumJSONRPC.{Blocks, Receipts}
  alias Explorer.Chain.Block, as: RollupBlock
  alias Explorer.Chain.Transaction, as: RollupTransaction
  alias Explorer.Repo

  alias Indexer.Fetcher.Arbitrum.Utils.Db, as: ArbitrumDbUtils

  alias Ecto.Multi

  require Logger

  def discover_blocks(end_block, state) do
    # Although it could be logical to limit the range of blocks to check
    # and then to backfill only by chunk size, larger buckets are more
    # efficient in cases where most blocks in the chain do not require
    # backfilling.
    start_block = max(state.config.rollup_rpc.first_block, end_block - state.config.backfill_blocks_depth + 1)

    if ArbitrumDbUtils.indexed_blocks?(start_block, end_block) do
      case do_discover_blocks(start_block, end_block, state) do
        :ok -> {:ok, start_block}
        :error -> {:error, :discover_blocks_error}
      end
    else
      log_warning(
        "Not able to discover rollup blocks to backfill, some blocks in #{start_block}..#{end_block} not indexed"
      )

      {:error, :not_indexed_blocks}
    end
  end

  defp do_discover_blocks(start_block, end_block, %{
         config: %{rollup_rpc: %{chunk_size: chunk_size, json_rpc_named_arguments: json_rpc_named_arguments}}
       }) do
    log_info("Block range for blocks information backfill: #{start_block}..#{end_block}")

    block_numbers = ArbitrumDbUtils.blocks_with_missing_fields(start_block, end_block)

    log_debug("Backfilling #{length(block_numbers)} blocks")

    backfill_for_blocks(block_numbers, json_rpc_named_arguments, chunk_size)
  end

  defp backfill_for_blocks([], _json_rpc_named_arguments, _chunk_size), do: :ok

  defp backfill_for_blocks(block_numbers, json_rpc_named_arguments, chunk_size) do
    with {:ok, blocks} <- fetch_blocks(block_numbers, json_rpc_named_arguments, chunk_size),
         {:ok, receipts} <- fetch_receipts(block_numbers, json_rpc_named_arguments, chunk_size) do
      update_db(blocks, receipts)
    else
      {:error, _} -> :error
    end
  end

  defp fetch_blocks(block_numbers, json_rpc_named_arguments, chunk_size) do
    block_numbers
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case EthereumJSONRPC.fetch_blocks_by_numbers(chunk, json_rpc_named_arguments, false) do
        {:ok, %Blocks{blocks_params: blocks}} -> {:cont, {:ok, acc ++ blocks}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_receipts(block_numbers, json_rpc_named_arguments, chunk_size) do
    block_numbers
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case Receipts.fetch_by_block_numbers(chunk, json_rpc_named_arguments) do
        {:ok, %{receipts: receipts}} -> {:cont, {:ok, acc ++ receipts}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_db([], []), do: :ok

  defp update_db(blocks, receipts) do
    log_info("Updating DB records for #{length(blocks)} blocks and #{length(receipts)} transactions")

    multi =
      Multi.new()
      |> update_blocks(blocks)
      |> update_transactions(receipts)

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, _} -> :error
      {:error, _, _, _} -> :error
    end
  end

  defp update_blocks(multi, []), do: multi

  defp update_blocks(multi, blocks) do
    blocks
    |> Enum.reduce(multi, fn block, multi_acc ->
      Multi.update_all(
        multi_acc,
        {:block, block.hash},
        from(b in RollupBlock, where: b.hash == ^block.hash),
        set: [
          send_count: block.send_count,
          send_root: block.send_root,
          l1_block_number: block.l1_block_number,
          updated_at: DateTime.utc_now()
        ]
      )
    end)
  end

  defp update_transactions(multi, []), do: multi

  defp update_transactions(multi, receipts) do
    receipts
    |> Enum.reduce(multi, fn receipt, multi_acc ->
      Multi.update_all(
        multi_acc,
        {:transaction, receipt.transaction_hash},
        from(t in RollupTransaction, where: t.hash == ^receipt.transaction_hash),
        set: [
          gas_used_for_l1: receipt.gas_used_for_l1,
          updated_at: DateTime.utc_now()
        ]
      )
    end)
  end
end
