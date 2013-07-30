require_relative 'test_helper'
require_relative 'code_workflow_example'

module Dynflow
  module ExecutionPlanTest
    describe ExecutionPlan do

      include PlanAssertions

      let :world do
        SimpleWorld.new
      end

      let :issues_data do
        [{ 'author' => 'Peter Smith', 'text' => 'Failing test' },
         { 'author' => 'John Doe', 'text' => 'Internal server error' }]
      end

      describe 'serialization' do

        let :execution_plan do
          world.plan(CodeWorkflowExample::FastCommit, 'sha' => 'abc123')
        end

        let :deserialized_execution_plan do
          world.persistence.load_execution_plan(execution_plan.id)
        end

        describe 'serialized execution plan' do

          before { execution_plan.save }

          it 'restores the plan properly' do
            deserialized_execution_plan.id.must_equal execution_plan.id

            assert_steps_equal execution_plan.root_plan_step, deserialized_execution_plan.root_plan_step
            assert_equal execution_plan.steps.keys, deserialized_execution_plan.steps.keys

            deserialized_execution_plan.steps.each do |id, step|
              assert_steps_equal(step, execution_plan.steps[id])
            end

            assert_run_flow_equal execution_plan, deserialized_execution_plan
          end

        end

      end

      describe '#result' do

        let :execution_plan do
          world.plan(CodeWorkflowExample::FastCommit, 'sha' => 'abc123')
        end

        describe 'for error in planning phase' do

          before { execution_plan.steps[2].state = :error }

          it 'should be :error' do
            execution_plan.result.must_equal :error
            execution_plan.error?.must_equal true
          end

        end


        describe 'for error in running phase' do

          before do
            step_id = execution_plan.run_flow.all_step_ids[2]
            execution_plan.steps[step_id].state = :error
          end

          it 'should be :error' do
            execution_plan.result.must_equal :error
          end

        end

        describe 'for pending step in running phase' do

          before do
            step_id = execution_plan.run_flow.all_step_ids[2]
            execution_plan.steps[step_id].state = :pending
          end

          it 'should be :pending' do
            execution_plan.result.must_equal :pending
          end

        end

        describe 'for all steps successful or skipped' do

          before do
            execution_plan.run_flow.all_step_ids.each_with_index do |step_id, index|
              step       = execution_plan.steps[step_id]
              step.state = (index == 2) ? :skipped : :success
            end
          end

          it 'should be :success' do
            execution_plan.result.must_equal :success
          end

        end

      end

      describe 'plan steps' do
        let :execution_plan do
          world.plan(CodeWorkflowExample::IncommingIssues, issues_data)
        end

        it 'stores the information about the sub actions' do
          assert_plan_steps <<-PLAN_STEPS, execution_plan
            IncommingIssues
              IncommingIssue
                Triage
                  UpdateIssue
                  NotifyAssignee
              IncommingIssue
                Triage
                  UpdateIssue
                  NotifyAssignee
          PLAN_STEPS
        end

      end

      describe 'planning algorithm' do

        describe 'single dependencies' do
          let :execution_plan do
            world.plan(CodeWorkflowExample::IncommingIssues, issues_data)
          end

          it 'constructs the plan of actions to be executed in run phase' do
            assert_run_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Concurrence
                Dynflow::Flows::Sequence
                  4: Triage(pending) {"author"=>"Peter Smith", "text"=>"Failing test"}
                  7: UpdateIssue(pending) {"triage_input"=>{"author"=>"Peter Smith", "text"=>"Failing test"}, "triage_output"=>Step(4).output}
                  9: NotifyAssignee(pending) {"triage"=>Step(4).output}
                Dynflow::Flows::Sequence
                  13: Triage(pending) {"author"=>"John Doe", "text"=>"Internal server error"}
                  16: UpdateIssue(pending) {"triage_input"=>{"author"=>"John Doe", "text"=>"Internal server error"}, "triage_output"=>Step(13).output}
                  18: NotifyAssignee(pending) {"triage"=>Step(13).output}
            RUN_FLOW
          end

        end

        describe 'multi dependencies' do
          let :execution_plan do
            world.plan(CodeWorkflowExample::Commit, 'sha' => 'abc123')
          end

          it 'constructs the plan of actions to be executed in run phase' do
            assert_run_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Sequence
                Dynflow::Flows::Concurrence
                  3: Ci(pending) {"commit"=>{"sha"=>"abc123"}}
                  5: Review(pending) {"commit"=>{"sha"=>"abc123"}, "reviewer"=>"Morfeus"}
                  7: Review(pending) {"commit"=>{"sha"=>"abc123"}, "reviewer"=>"Neo"}
                9: Merge(pending) {"commit"=>{"sha"=>"abc123"}, "ci_output"=>Step(3).output, "review_outputs"=>[Step(5).output, Step(7).output]}
            RUN_FLOW
          end
        end

        describe 'sequence and concurrence keyword used' do
          let :execution_plan do
            world.plan(CodeWorkflowExample::FastCommit, 'sha' => 'abc123')
          end

          it 'constructs the plan of actions to be executed in run phase' do
            assert_run_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Sequence
                Dynflow::Flows::Concurrence
                  3: Ci(pending) {"commit"=>{"sha"=>"abc123"}}
                  5: Review(pending) {"commit"=>{"sha"=>"abc123"}, "reviewer"=>"Morfeus"}
                7: Merge(pending) {"commit"=>{"sha"=>"abc123"}}
            RUN_FLOW
          end
        end

        describe 'finalize flow' do

          let :execution_plan do
            world.plan(CodeWorkflowExample::IncommingIssues, issues_data)
          end

          it 'plans the finalize steps in a sequence' do
            assert_finalize_flow <<-RUN_FLOW, execution_plan
              Dynflow::Flows::Sequence
                5: Triage(pending) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"}
                10: NotifyAssignee(pending) {\"triage\"=>Step(4).output}
                14: Triage(pending) {\"author\"=>\"John Doe\", \"text\"=>\"Internal server error\"}
                19: NotifyAssignee(pending) {\"triage\"=>Step(13).output}
                20: IncommingIssues(pending) {\"issues\"=>[{\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"}, {\"author\"=>\"John Doe\", \"text\"=>\"Internal server error\"}]}
            RUN_FLOW
          end

        end
      end
    end
  end
end
