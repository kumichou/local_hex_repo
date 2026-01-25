defmodule LocalHexWeb.PackageHTML do
  use LocalHexWeb, :html

  alias LocalHex.Storage

  embed_templates "package_html/*"

  def package_dom_id(package, version) do
    package.name <> "-" <> String.replace(version, ".", "_")
  end

  def package_clipboard(repo, package, version) do
    "{:" <> package.name <> ", \"~> " <> version <> "\", repo: :" <> repo.name <> "}"
  end

  def docs_uploaded?(repo, package_name, version) do
    Storage.docs_tarball_exists?(repo, package_name, version)
  end
end
