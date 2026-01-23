defmodule LocalHex.Mirror.Publish do
  @moduledoc false

  require Logger

  alias LocalHex.{Package, Repository, Storage}
  alias LocalHex.Mirror.{HexApi, RateLimiter}

  @default_batch_size 25
  @default_pause_min_ms 200
  @default_pause_max_ms 500
  @default_pkg_concurrency 2
  @default_tarball_concurrency 2

  @doc """
  Ensure all transitive deps (latest matching) exist in the mirror.

  Intended to be called after publishing a private package to the main repo.
  """
  def mirror_transitive_deps(%Repository{} = mirror, %Package{} = pkg) do
    opts = mirror.options || %{}

    include_optional? = Map.get(opts, :include_optional_deps, false)
    batch_size = Map.get(opts, :batch_size, @default_batch_size)
    pause_min_ms = Map.get(opts, :batch_pause_min_ms, @default_pause_min_ms)
    pause_max_ms = Map.get(opts, :batch_pause_max_ms, @default_pause_max_ms)
    pkg_concurrency = Map.get(opts, :max_package_fetch_concurrency, @default_pkg_concurrency)
    tarball_concurrency = Map.get(opts, :max_tarball_fetch_concurrency, @default_tarball_concurrency)

    deps =
      pkg.release.dependencies
      |> Enum.reject(fn dep ->
        (not include_optional? and Map.get(dep, :optional, false)) or
          # If a dependency points at a different repository, don't mirror it from hex.pm.
          Map.get(dep, :repository) not in [nil, "hexpm"]
      end)

    Logger.info(
      "#{inspect(__MODULE__)} eager mirror on publish for #{pkg.name}@#{pkg.version} deps=#{length(deps)}"
    )

    {resolved, cache} = resolve_closure(mirror, deps, %{}, %{}, pkg_concurrency)

    # Persist a small manifest for audit/debugging (stored in mirror backend)
    persist_manifest(mirror, pkg, resolved)

    resolved_list =
      resolved
      |> Enum.map(fn {name, version} -> {name, version} end)
      |> Enum.sort()

    ensure_releases(mirror, resolved_list, cache, tarball_concurrency, batch_size, pause_min_ms, pause_max_ms)

    # Refresh the mirror's signed indexes for just what we mirror.
    refresh_indexes(mirror)
  end

  defp resolve_closure(mirror, deps, resolved, cache, pkg_concurrency) do
    initial =
      deps
      |> Enum.map(fn %{package: name, requirement: req} -> {name, req} end)
      |> Enum.uniq()

    resolve_queue(mirror, initial, resolved, cache, pkg_concurrency)
  end

  defp resolve_queue(_mirror, [], resolved, cache, _pkg_concurrency), do: {resolved, cache}

  defp resolve_queue(mirror, queue, resolved, cache, pkg_concurrency) do
    # Resolve a small slice concurrently to avoid long serial chains.
    {batch, rest} = Enum.split(queue, pkg_concurrency)

    stream =
      Task.Supervisor.async_stream_nolink(
        LocalHex.TaskSupervisor,
        batch,
        fn {name, requirement} ->
          resolve_one(mirror, name, requirement, cache)
        end,
        max_concurrency: pkg_concurrency,
        ordered: false,
        timeout: 60_000
      )

    {new_queue, resolved, cache} =
      Enum.reduce(stream, {rest, resolved, cache}, fn
        {:ok, {:skip, _name}}, acc ->
          acc

        {:ok, {:ok, name, version, deps, new_cache}}, {q, r, c} ->
          r = Map.put(r, name, version)
          c = Map.merge(c, new_cache)

          next =
            deps
            |> Enum.map(fn %{package: dep_name, requirement: dep_req} -> {dep_name, dep_req} end)
            |> Enum.reject(fn {dep_name, _} -> Map.has_key?(r, dep_name) end)

          {q ++ next, r, c}

        {:exit, reason}, _acc ->
          raise "Dependency resolution crashed: #{inspect(reason)}"

        {:error, reason}, _acc ->
          raise "Dependency resolution failed: #{inspect(reason)}"
      end)

    resolve_queue(mirror, new_queue, resolved, cache, pkg_concurrency)
  end

  defp resolve_one(mirror, name, requirement, cache) do
    # If already cached, don't refetch the package metadata.
    {pkg, cache} =
      case Map.fetch(cache, name) do
        {:ok, pkg} ->
          {pkg, cache}

        :error ->
          RateLimiter.wait()
          {:ok, signed} = HexApi.fetch_hexpm_package(mirror, name)
          {:ok, decoded} = decode_hexpm_package(mirror, signed, name)
          {decoded, Map.put(cache, name, decoded)}
      end

    chosen =
      choose_latest_matching_version(
        Enum.map(pkg.releases, & &1.version),
        requirement
      )

    case chosen do
      nil ->
        raise "No version of #{name} satisfies #{inspect(requirement)}"

      version ->
        release = Enum.find(pkg.releases, fn r -> r.version == version end)
        {:ok, name, version, release.dependencies, cache}
    end
  end

  defp choose_latest_matching_version(versions, requirement) do
    with {:ok, req} <- Version.parse_requirement(requirement) do
      versions
      |> Enum.filter(fn v ->
        case Version.parse(v) do
          {:ok, ver} -> Version.match?(ver, req)
          :error -> false
        end
      end)
      |> Enum.max_by(fn v -> Version.parse!(v) end, fn -> nil end)
    else
      :error ->
        raise "Invalid version requirement: #{inspect(requirement)}"
    end
  end

  defp ensure_releases(mirror, resolved_list, cache, tarball_concurrency, batch_size, pause_min_ms, pause_max_ms) do
    mirror = Repository.load(mirror)

    resolved_list
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce(mirror, fn chunk, mirror ->
      Logger.info("#{inspect(__MODULE__)} mirroring batch size=#{length(chunk)}")

      stream =
        Task.Supervisor.async_stream_nolink(
          LocalHex.TaskSupervisor,
          chunk,
          fn {name, version} ->
            ensure_release(mirror, name, version, cache)
          end,
          max_concurrency: tarball_concurrency,
          ordered: false,
          timeout: 120_000
        )

      updated_registry =
        Enum.reduce(stream, mirror.registry, fn
          {:ok, {:ok, name, releases}}, registry ->
            Map.put(registry, name, releases)

          {:ok, :ok}, registry ->
            registry

          {:exit, reason}, _registry ->
            raise "Mirroring task crashed: #{inspect(reason)}"

          {:error, reason}, _registry ->
            raise "Mirroring task failed: #{inspect(reason)}"
        end)

      mirror = %{mirror | registry: updated_registry}
      Repository.save(mirror)

      pause_ms = pause_min_ms + :rand.uniform(max(1, pause_max_ms - pause_min_ms + 1)) - 1
      Process.sleep(pause_ms)

      mirror
    end)

    :ok
  end

  defp ensure_release(mirror, name, version, cache) do
    # Ensure tarball exists
    tarball_name = "#{name}-#{version}.tar"

    case Storage.read_package_tarball(mirror, tarball_name) do
      {:ok, _} ->
        :ok

      _ ->
        RateLimiter.wait()
        {:ok, tarball} = HexApi.fetch_hexpm_tarball(mirror, name, version)
        {:ok, package} = Package.load_from_tarball(tarball)
        :ok = Storage.write_package_tarball(mirror, package)
    end

    # Ensure /packages/:name exists and includes the chosen release.
    releases = Map.get(mirror.registry, name, [])

    if Enum.any?(releases, fn r -> r.version == version end) do
      :ok
    else
      upstream_pkg = Map.fetch!(cache, name)
      release = Enum.find(upstream_pkg.releases, fn r -> r.version == version end)
      new_releases = [release | releases] |> Enum.uniq_by(& &1.version)
      signed = encode_package(mirror, name, new_releases)
      :ok = Storage.write_package(mirror, name, signed)
      {:ok, name, new_releases}
    end
  end

  defp refresh_indexes(mirror) do
    mirror = Repository.load(mirror)
    allowed = Map.keys(mirror.registry) |> MapSet.new()

    # names
    RateLimiter.wait()
    {:ok, signed_names} = HexApi.fetch_hexpm_names(mirror)
    {:ok, %{packages: names}} = decode_hexpm_names(mirror, signed_names)
    names = Enum.filter(names, fn %{name: n} -> MapSet.member?(allowed, n) end)
    :ok = Storage.write_names(mirror, encode_names(mirror, names))

    # versions
    RateLimiter.wait()
    {:ok, signed_versions} = HexApi.fetch_hexpm_versions(mirror)
    {:ok, %{packages: versions}} = decode_hexpm_versions(mirror, signed_versions)
    versions = Enum.filter(versions, fn %{name: n} -> MapSet.member?(allowed, n) end)
    :ok = Storage.write_versions(mirror, encode_versions(mirror, versions))

    :ok
  end

  defp persist_manifest(mirror, %Package{} = pkg, resolved) do
    body =
      %{
        "published" => %{"name" => pkg.name, "version" => pkg.version},
        "resolved" => Map.new(resolved),
        "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> Jason.encode!()

    Storage.write(mirror, ["manifests", pkg.name, "#{pkg.version}.json"], body)
  end

  # Minimal copies of Sync's encoding/decoding helpers (kept private there today).
  defp encode_names(repository, names) do
    protobuf =
      :hex_registry.encode_names(%{
        repository: repository.name,
        packages: names
      })

    sign_and_gzip(repository, protobuf)
  end

  defp encode_versions(repository, versions) do
    protobuf =
      :hex_registry.encode_versions(%{
        repository: repository.name,
        packages: versions
      })

    sign_and_gzip(repository, protobuf)
  end

  defp encode_package(repository, name, releases) do
    protobuf =
      :hex_registry.encode_package(%{
        repository: repository.name,
        name: name,
        releases: releases
      })

    sign_and_gzip(repository, protobuf)
  end

  defp sign_and_gzip(repository, protobuf) do
    protobuf
    |> :hex_registry.sign_protobuf(repository.private_key)
    |> :zlib.gzip()
  end

  defp decode_hexpm_names(repository, body) do
    {:ok, payload} = decode_and_verify_signed(body, repository)
    :hex_registry.decode_names(payload, repository.options.upstream_name)
  end

  defp decode_hexpm_versions(repository, body) do
    {:ok, payload} = decode_and_verify_signed(body, repository)
    :hex_registry.decode_versions(payload, repository.options.upstream_name)
  end

  defp decode_hexpm_package(repository, body, name) do
    {:ok, payload} = decode_and_verify_signed(body, repository)
    :hex_registry.decode_package(payload, repository.options.upstream_name, name)
  end

  defp decode_and_verify_signed(body, repository) do
    body
    |> :zlib.gunzip()
    |> :hex_registry.decode_and_verify_signed(repository.options.upstream_public_key)
  end
end
