export const ExamAnswers = {
  mounted() {
    this.onKeydown = event => {
      if (event.key === "Enter" && !event.isComposing && event.target.matches("input:not([type=submit]):not([type=button]):not([type=reset])")) {
        event.preventDefault()
      }
    }
    this.el.addEventListener("keydown", this.onKeydown)
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
  }
}
