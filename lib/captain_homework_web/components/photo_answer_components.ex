defmodule CaptainHomeworkWeb.PhotoAnswerComponents do
  use Phoenix.Component
  import CaptainHomeworkWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :upload_name, :string, default: nil

  def webcam_capture(assigns) do
    ~H"""
    <div id={@id} phx-hook="WebcamCapture" phx-update="ignore" data-upload-name={@upload_name}>
      <button type="button" class="button" data-camera-open>
        <.icon name="camera" /> Utiliser la webcam
      </button>
      <dialog class="webcam-dialog" aria-labelledby={@id <> "-title"}>
        <div class="webcam-content">
          <div class="section-heading">
            <h2 id={@id <> "-title"}>Cadre ta réponse</h2>
            <button type="button" class="button" data-camera-close>Fermer</button>
          </div>
          <p>Place ta feuille dans le cadre. Vérifie que ton écriture est nette et bien éclairée.</p>
          <div class="webcam-stage">
            <video autoplay playsinline muted data-camera-video></video>
            <img data-camera-preview hidden alt="Photo à vérifier avant de l’utiliser" />
            <div class="webcam-frame" aria-hidden="true"></div>
          </div>
          <p data-camera-status role="status" aria-live="polite"></p>
          <div class="form-actions">
            <button type="button" class="button" data-camera-retry hidden>Recommencer</button>
            <button type="button" class="button primary" data-camera-shoot disabled>
              Prendre la photo
            </button>
            <button type="button" class="button primary" data-camera-use hidden>
              Utiliser cette photo
            </button>
          </div>
        </div>
      </dialog>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :src, :string, default: nil
  attr :filename, :string, default: nil
  attr :show_filename, :boolean, default: false
  attr :local_preview, :boolean, default: false
  slot :picker
  slot :remove
  slot :image

  def photo_answer(assigns) do
    ~H"""
    <div id={@id} class="photo-response">
      <div data-photo-empty hidden={!!@src or @image != []} class="photo-response-empty">
        <span class="photo-response-icon"><.icon name="camera" /></span>
        <strong>
          {if @picker == [], do: "Aucune photo fournie", else: "Ajoute la photo de ton dessin"}
        </strong>
        <p :if={@picker != []}>
          Pose ta feuille à plat et cadre toute la figure, avec les lettres et les mesures.
        </p>
      </div>
      <div data-photo-preview hidden={!@src and @image == []} class="photo-response-preview">
        <%= if @image != [] do %>
          {render_slot(@image)}
        <% else %>
          <img data-photo src={@src} alt="Photo de ta réponse" />
        <% end %>
        <p :if={@show_filename} data-photo-name class="muted">{@filename}</p>
      </div>
      <div :if={@picker != [] or @remove != []} class="photo-response-actions">
        {render_slot(@picker)}
        {render_slot(@remove)}
      </div>
      <p :if={@local_preview} data-photo-error role="alert" class="notice error" hidden></p>
    </div>
    """
  end
end
