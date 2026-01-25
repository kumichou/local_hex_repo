defmodule LocalHex.Storage do
  @moduledoc """
  Wrapper around File module for write, read and delete actions.

  For now only local!
  This will later serve as behavior to allow other storage methods in addtion
  like S3, FTP to name a few.
  """

  require Logger

  alias LocalHex.{Documentation, Package, Repository}
  alias ExAws.S3

  @callback write(repository :: Repository.t(), path :: binary, value :: binary) ::
              :ok | {:error, term}

  @callback read(repository :: Repository.t(), path :: binary) ::
              {:ok, binary} | {:error, term}

  @callback delete(repository :: Repository.t(), path :: binary) ::
              :ok | {:error, term}

  def write_repository(repository, content) do
    write(repository, repository_file_path(repository), content)
  end

  def write_names(repository, content) do
    write(repository, names_path(), content)
  end

  def write_versions(repository, content) do
    write(repository, versions_path(), content)
  end

  def write_package(repository, name, content) do
    write(repository, package_path(name), content)
  end

  def write_package_tarball(repository, package) do
    write(repository, package_tarball_path(package), package.tarball)
  end

  def write_docs_tarball(repository, documentation) do
    write(repository, docs_tarball_path(documentation), documentation.tarball)
  end

  def write(repository, path, value) do
    {adapter_module, _} = repository.store
    adapter_module.write(repository, path, value)
  end

  def read_repository(repository) do
    read(repository, repository_file_path(repository))
  end

  def read_names(repository) do
    read(repository, names_path())
  end

  def read_versions(repository) do
    read(repository, versions_path())
  end

  def read_package(repository, name) do
    read(repository, package_path(name))
  end

  def read_package_tarball(repository, tarball) do
    read(repository, package_tarball_path(tarball))
  end

  def read_docs_tarball(repository, tarball) do
    read(repository, docs_tarball_path(tarball))
  end

  def read(repository, path) do
    {adapter_module, _} = repository.store
    adapter_module.read(repository, path)
  end

  def delete_package(repository, name) do
    delete(repository, package_path(name))
  end

  def delete_package_tarball(repository, tarball) do
    delete(repository, package_tarball_path(tarball))
  end

  @doc """
  Returns true if the docs tarball exists for `name`/`version`.

  This is used by the Web UI to hide "Docs" links for internal packages that
  never uploaded docs.
  """
  def docs_tarball_exists?(repository, name, version)
      when is_binary(name) and is_binary(version) do
    tarball = "#{name}-#{version}.tar"
    storage_exists?(repository, ["docs", name, tarball])
  end

  def delete(repository, path) do
    {adapter_module, _} = repository.store
    adapter_module.delete(repository, path)
  end

  defp storage_exists?(repository, path) do
    case repository.store do
      {LocalHex.Storage.Local, opts} when is_list(opts) ->
        File.exists?(local_file_path(repository, opts, path))

      {LocalHex.Storage.S3, opts} when is_list(opts) ->
        s3_object_exists?(repository, opts, path)

      _ ->
        false
    end
  end

  defp local_file_path(repository, opts, path) do
    root = local_root_path(opts)
    Path.join([root, repository.name | List.wrap(path)])
  end

  defp local_root_path(root: {app, path}) when is_atom(app) and is_binary(path) do
    Application.app_dir(app, path)
  end

  defp local_root_path(root: path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(Application.app_dir(:local_hex), path)
    end
  end

  defp s3_object_exists?(repository, opts, path) do
    bucket = Keyword.fetch!(opts, :bucket)
    s3_opts = Keyword.get(opts, :options, [])
    key = Path.join(["", repository.name | List.wrap(path)])

    request = S3.head_object(bucket, key, s3_opts)

    case ExAws.request(request, s3_opts) do
      {:ok, _} ->
        true

      {:error, {:http_error, 404, _}} ->
        false

      {:error, other} ->
        Logger.debug("#{inspect(__MODULE__)} head_object failed: #{inspect(other)}")
        false
    end
  end

  defp repository_file_path(repository) do
    repository.name <> ".bin"
  end

  defp names_path do
    ["names"]
  end

  defp versions_path do
    ["versions"]
  end

  defp package_path(package_name) do
    ["packages", "#{package_name}"]
  end

  defp package_tarball_path(%Package{} = package) do
    ["tarballs", package.name, "#{package.name}-#{package.version}.tar"]
  end

  defp package_tarball_path(tarball) do
    package_name = extract_name_from_tar_filename(tarball)
    ["tarballs", package_name, tarball]
  end

  defp docs_tarball_path(%Documentation{} = documentation) do
    ["docs", documentation.name, "#{documentation.name}-#{documentation.version}.tar"]
  end

  defp docs_tarball_path(tarball) do
    package_name = extract_name_from_tar_filename(tarball)
    ["docs", package_name, tarball]
  end

  defp extract_name_from_tar_filename(tarball) do
    regex = ~r/\A(?<package_name>[a-zA-Z_-]*)-\d+\.\d+\.\d+\.tar\z/

    case Regex.named_captures(regex, tarball) do
      %{"package_name" => package_name} ->
        package_name

      _ ->
        "default"
    end
  end
end
