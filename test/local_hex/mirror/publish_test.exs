defmodule LocalHex.Mirror.PublishTest do
  use LocalHex.MirrorCase

  import Mox

  alias LocalHex.Mirror.Publish
  alias LocalHex.Package
  alias LocalHex.Repository

  setup :verify_on_exit!

  defp build_tarball!(name, version, requirements) do
    metadata = %{
      "name" => name,
      "version" => version,
      "requirements" => requirements
    }

    files = [{~c"mix.exs", "IO.puts(\"#{name}\")" |> :erlang.iolist_to_binary()}]

    {:ok, %{tarball: tarball}} = :hex_tarball.create(metadata, files)
    tarball
  end

  test "publish-driven mirroring eagerly mirrors transitive deps (latest matching) and persists manifest" do
    mirror =
      repository()
      |> Map.update!(:options, fn opts ->
        opts
        |> Map.merge(%{
          # Keep the test fast/deterministic
          batch_size: 1,
          batch_pause_min_ms: 0,
          batch_pause_max_ms: 0,
          max_package_fetch_concurrency: 2,
          max_tarball_fetch_concurrency: 2
        })
      end)
      |> Repository.save()
      |> Repository.load()

    # Published private package depends on the mirror packages.
    private_tarball =
      build_tarball!("private_pkg", "1.0.0", %{
        "example_lib" => %{"requirement" => "~> 0.1.0"},
        "another_lib" => %{"requirement" => "~> 0.1.0"}
      })

    {:ok, private_pkg} = Package.load_from_tarball(private_tarball)

    # Upstream tarballs (keep them minimal/no deps so the test stays focused).
    example_010 = build_tarball!("example_lib", "0.1.0", %{})
    example_020 = build_tarball!("example_lib", "0.2.0", %{})
    another_010 = build_tarball!("another_lib", "0.1.0", %{})

    {:ok, example_pkg_010} = Package.load_from_tarball(example_010)
    {:ok, example_pkg_020} = Package.load_from_tarball(example_020)
    {:ok, another_pkg_010} = Package.load_from_tarball(another_010)

    MockHexApi
    |> expect(:fetch_hexpm_package, 2, fn
      _, "example_lib" ->
        # Upstream has 0.1.0 and 0.2.0 but we should pick 0.1.0 for "~> 0.1.0"
        {:ok, upstream_encode_package("example_lib", [example_pkg_010, example_pkg_020])}

      _, "another_lib" ->
        {:ok, upstream_encode_package("another_lib", [another_pkg_010])}
    end)
    |> expect(:fetch_hexpm_tarball, 2, fn
      _, "example_lib", "0.1.0" -> {:ok, example_010}
      _, "another_lib", "0.1.0" -> {:ok, another_010}
    end)
    |> expect(:fetch_hexpm_names, 1, fn _ ->
      {:ok,
       upstream_encode_names([
         %{name: "example_lib", updated_at: %{nanos: 0, seconds: 0}},
         %{name: "another_lib", updated_at: %{nanos: 0, seconds: 0}}
       ])}
    end)
    |> expect(:fetch_hexpm_versions, 1, fn _ ->
      {:ok,
       upstream_encode_versions([
         %{name: "example_lib", retired: [], versions: ["0.1.0", "0.2.0"]},
         %{name: "another_lib", retired: [], versions: ["0.1.0"]}
       ])}
    end)

    :ok = Publish.mirror_transitive_deps(mirror, private_pkg)

    # Manifest written for the published package
    assert File.exists?(path(mirror, ["manifests", "private_pkg", "1.0.0.json"]))

    # Tarballs written only for the resolved versions
    assert File.exists?(path(mirror, ["tarballs", "example_lib", "example_lib-0.1.0.tar"]))
    refute File.exists?(path(mirror, ["tarballs", "example_lib", "example_lib-0.2.0.tar"]))
    assert File.exists?(path(mirror, ["tarballs", "another_lib", "another_lib-0.1.0.tar"]))

    # Mirror index artifacts updated
    assert File.exists?(path(mirror, ["names"]))
    assert File.exists?(path(mirror, ["versions"]))
  end
end
