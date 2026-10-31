defmodule CaptainHomeworkWeb.Router do
  use CaptainHomeworkWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CaptainHomeworkWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
      "referrer-policy" => "same-origin",
      "x-robots-tag" => "noindex, nofollow"
    }
  end

  pipeline :family do
    plug CaptainHomeworkWeb.Access, :require_access
  end

  get "/health", CaptainHomeworkWeb.SessionController, :health

  scope "/", CaptainHomeworkWeb do
    pipe_through :browser
    get "/connexion", SessionController, :login
    post "/connexion", SessionController, :authenticate
    delete "/session", SessionController, :logout
    pipe_through :family
    post "/profil", SessionController, :profile
    get "/pages/:id", PageController, :show
    get "/enfants/:child/pages/:id", PageController, :show
    get "/:child/pages/:id", PageController, :show
    get "/:child/ressources/:id", ResourceController, :show
    get "/:child/controles/:exam_id/images/:id", ExamImageController, :show
    get "/controles/:exam_id/images/:id", ExamImageController, :show

    live_session :family, on_mount: [{CaptainHomeworkWeb.Access, :ensure_access}] do
      live "/", HomeworkLive, :home
      live "/parametres", HomeworkLive, :settings
      live "/matieres/:subject", HomeworkLive, :subject
      live "/lecons/:id", HomeworkLive, :lesson
      live "/lecons/:id/controle", HomeworkLive, :new_exam
      live "/controles/:id", HomeworkLive, :exam
      live "/enfants/:child", HomeworkLive, :home
      live "/enfants/:child/parametres", HomeworkLive, :settings
      live "/enfants/:child/matieres/:subject", HomeworkLive, :subject
      live "/enfants/:child/lecons/:id", HomeworkLive, :lesson
      live "/enfants/:child/lecons/:id/controle", HomeworkLive, :new_exam
      live "/enfants/:child/controles/:id", HomeworkLive, :exam
      live "/:child", HomeworkLive, :home
      live "/:child/parametres", HomeworkLive, :settings
      live "/:child/matieres/:subject", HomeworkLive, :subject
      live "/:child/lecons/:id", HomeworkLive, :lesson
      live "/:child/lecons/:id/controle", HomeworkLive, :new_exam
      live "/:child/controles/:id", HomeworkLive, :exam
    end
  end
end
