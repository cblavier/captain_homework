defmodule CaptainHomework.Study.ExamQuestionDefinition do
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :binary_id
  schema "exam_question_definitions" do
    belongs_to :exam, CaptainHomework.Study.Exam, primary_key: true
    belongs_to :definition, CaptainHomework.Study.QuestionDefinition, primary_key: true
    field :snapshot, :map
  end
end
