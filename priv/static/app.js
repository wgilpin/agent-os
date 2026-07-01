// Phoenix LiveView connection bootstrapping
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {}

Hooks.ScrollToBottom = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight;
  },
  updated() {
    this.el.scrollTop = this.el.scrollHeight;
  }
}

// Global Phoenix and LiveView are loaded via <script> tags from dependencies
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
});

// Connect to the LiveView endpoint
liveSocket.connect();

// Expose LiveSocket for debugging
window.liveSocket = liveSocket;
