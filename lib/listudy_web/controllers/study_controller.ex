defmodule ListudyWeb.StudyController do
  use ListudyWeb, :controller

  alias Listudy.Users
  alias Listudy.Users.User
  alias Listudy.Studies
  alias Listudy.Studies.Study
  alias Listudy.StudyFavorites
  alias Listudy.StudyFavorites.StudyFavorite
  alias Listudy.Comments
  alias Listudy.Comments.StudyComment


  def index(conn, _params) do
    user = case get_user(conn) do
      {:ok, user} -> user
      {:error, _} -> -1
    end

    studies = Studies.get_study_by_user!(user)
    favorites = Studies.get_studies_by_favorite!(user)
    render(conn, "index.html", studies: studies, favorites: favorites)
  end

  def new(conn, _params) do
    case get_user(conn) do
      {:ok, _} ->
        changeset = Studies.change_study(%Study{})
        render(conn, "new.html", changeset: changeset)
      {:error, error} ->
        conn
        |> put_flash(:info, error)
        |> redirect(to: Routes.pow_registration_path(conn, :new))
    end
  end

  def create(conn, %{"study" => study_params}) do
    with {:ok, creator} <- get_user(conn),
         {:ok, pgn} <- check_pgn(study_params)
    do
      # create a slug from the title
      id = Listudy.Slug.random_alnum
      title_slug = Listudy.Slug.slugify(study_params["title"])
      slug = create_slug(id, title_slug)
      study_params = Map.put(study_params, "slug", slug)

      # Reference the logged in user as creator
      study_params = Map.put(study_params, "user_id", creator)
      
      # keep the uploaded file
      file = id <> ".pgn"
      File.cp(pgn.path, get_path(file))

      case Studies.create_study(study_params) do
        {:ok, study} ->
          conn
          |> put_flash(:info, "Study created successfully.")
          |> redirect(to: Routes.study_path(conn, :show, conn.private.plug_session["locale"], study))

        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, "new.html", changeset: changeset)
      end
    else
      {:error, reason} ->
        changeset = Studies.change_study(%Study{})
        conn 
          |> put_flash(:info, reason)
          |> render("new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    study = Studies.get_study_by_slug!(id)
    
    user_id = case get_user(conn) do
      {:ok, user} -> user
      {:error, _} -> -1
    end

    if (study != nil or !study.private or study.user_id == user_id) do
      study = Map.put(study, :is_owner, study.user_id == user_id)
      # todo maybe reduce the number of extra querys
      study = Map.put(study, :favorites, StudyFavorites.user_favorites_study(user_id, study.id) )
      study = Map.put(study, :user, Users.get_user!(study.user_id)) 
      [unique_id|_] = id |> String.split("-")
      file = unique_id <> ".pgn"
      {_, pgn} = File.read(get_path(file))
      study = Map.put(study, :pgn, pgn)
      render(conn, "show.html", study: study)
    else
      conn
      |> put_flash(:info, "This study is private.")
      |> redirect(to: Routes.study_path(conn, :index, conn.private.plug_session["locale"]))
    end
  end

  def edit(conn, %{"id" => id}) do
    study = Studies.get_study_by_slug!(id)
    changeset = Studies.change_study(study)
    render(conn, "edit.html", study: study, changeset: changeset)
  end

  def update(conn, %{"id" => id, "study" => study_params}) do
    study = Studies.get_study_by_slug!(id)
    {_, user} = get_user(conn)
    [unique_id|_] = id |> String.split("-")
    file = unique_id <> ".pgn"
    title_slug = Listudy.Slug.slugify(study_params["title"])
    slug = create_slug(unique_id, title_slug)
    study_params = Map.put(study_params, "slug", slug)

    if allowed(study,user) do
      case Studies.update_study(study, study_params) do
        {:ok, study} ->
          case check_pgn(study_params) do
            {:ok, pgn} -> File.cp(pgn.path, get_path(file))
            _ -> false
          end
          conn
            |> put_flash(:info, "Study updated successfully.")
            |> redirect(to: Routes.study_path(conn, :show, conn.private.plug_session["locale"], study))

        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, "edit.html", study: study, changeset: changeset)
      end
    else
      conn
        |> put_flash(:info, "You're not allowed to do that.")
        |> redirect(to: Routes.study_path(conn, :index, conn.private.plug_session["locale"]))
    end
  end

  def delete(conn, %{"id" => id}) do
    study = Studies.get_study_by_slug!(id)
    
    {_, user} = get_user(conn)

    if !allowed(study, user) do
      conn
      |> put_flash(:info, "You're not allowed to do that.")
      |> redirect(to: Routes.study_path(conn, :index, conn.private.plug_session["locale"]))
    else 
      {:ok, _study} = Studies.delete_study(study)
      conn
      |> put_flash(:info, "Study deleted successfully.")
      |> redirect(to: Routes.study_path(conn, :index, conn.private.plug_session["locale"]))
    end
  end

  defp create_slug(id, title_slug) do
    id <> "-" <> title_slug
  end

  defp allowed(study, user) do
    study.user_id == user
  end

  defp get_user(conn) do
    case Pow.Plug.current_user(conn) != nil do
      true -> {:ok, Pow.Plug.current_user(conn).id}
      _ -> {:error, gettext "Please log in"}
    end
  end

  defp check_pgn(study_params) do
    if study_params["pgn"] == nil do
      {:error, gettext "No PGN file uploaded"}
    else
      file = study_params["pgn"].path
      case File.stat file do
        {:ok, %{size: size}} -> if size < 50000 do
            {:ok, study_params["pgn"]}
          else
            {:error, gettext "PGN is too big, only 50kb allowed"}
          end
        {:error, _} -> "Error"
        end
    end
  end

  defp get_path(file) do
    "priv/static/study_pgn/" <> file
  end

  def favorite_study(conn, %{ "study_id" => study_id}) do
    user_id = Pow.Plug.current_user(conn).id

    {_, message} = case StudyFavorites.favorite_study(%{study_id: study_id, user_id: user_id}) do
      {:ok, _} -> {:ok, gettext "Study favorited"}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, gettext "Could not favorite this study"}
    end

    conn
    |> put_flash(:info, message)
    |> redirect(to: NavigationHistory.last_path(conn))
  end

  def unfavorite_study(conn, %{ "study_id" => study_id}) do
    user_id = Pow.Plug.current_user(conn).id

    {_, message} = case StudyFavorites.unfavorite_study(user_id, study_id) do
      {:ok, _} -> {:ok, gettext "Study unfavorited"}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, gettext "Could not unfavorite this study"}
    end

    conn
    |> put_flash(:info, message)
    |> redirect(to: NavigationHistory.last_path(conn))
  end

end
