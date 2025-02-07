require 'rabl'

module Surveyor
  module Models
    module ResponseSetMethods
      def self.included(base)
        # Associations
        base.send :belongs_to, :survey
        base.send :belongs_to, :user
        base.instance_eval {has_many :responses, ->{order "#{Response.quoted_table_name}.created_at ASC"}, :dependent => :destroy}
        base.send :accepts_nested_attributes_for, :responses, :allow_destroy => true

        @@validations_already_included ||= nil
        unless @@validations_already_included
          # Validations
          base.send :validates_presence_of, :survey_id
          base.send :validates_associated, :responses
          base.send :validates_uniqueness_of, :access_code

          @@validations_already_included = true
        end

        # Attributes
        #base.send :attr_protected, :completed_at

        # Whitelisting attributes
        #base.send :attr_accessible, :survey, :responses_attributes, :user_id, :survey_id

        base.send :before_create, :ensure_start_timestamp
        base.send :before_create, :ensure_identifiers

        # Class methods
        base.instance_eval do
          def has_blank_value?(hash)
            return true if hash["answer_id"].blank?
            return false if (q = Question.find_by_id(hash["question_id"])) and q.pick == "one"
            puts "In has_blank_value? #{hash.class} :: #{hash.inspect} "
            hash.to_h.any?{|k,v| v.is_a?(Array) ? v.all?{|x| x.to_s.blank?} : v.to_s.blank?}
          end
        end
      end

      def ensure_start_timestamp
        self.started_at ||= Time.now
      end

      def ensure_identifiers
        self.access_code ||= Surveyor::Common.make_tiny_code
        self.api_id ||= Surveyor::Common.generate_api_id
      end

      def to_csv(access_code = false, print_header = true)
        qcols = Question.content_columns.map(&:name) - %w(created_at updated_at)
        acols = Answer.content_columns.map(&:name) - %w(created_at updated_at)
        rcols = Response.content_columns.map(&:name)
        result = Surveyor::Common.csv_impl.generate do |csv|
          if print_header
            csv << (access_code ? ["response set access code"] : []) +
              qcols.map{|qcol| "question.#{qcol}"} +
              acols.map{|acol| "answer.#{acol}"} +
              rcols.map{|rcol| "response.#{rcol}"}
          end
          responses.each do |response|
            csv << (access_code ? [self.access_code] : []) +
              qcols.map{|qcol| response.question.send(qcol)} +
              acols.map{|acol| response.answer.send(acol)} +
              rcols.map{|rcol| response.send(rcol)}
          end
        end
        result
      end

      def as_json(options = nil)
        template_paths = ActionController::Base.view_paths.collect(&:to_path)
        Rabl.render(self, 'surveyor/show.json', :view_path => template_paths, :format => "hash")
      end

      def complete!
        self.completed_at = Time.now
      end

      def complete?
        !completed_at.nil?
      end

      def correct?
        responses.all?(&:correct?)
      end
      def correctness_hash
        { :questions => survey.sections_with_questions.map(&:questions).flatten.compact.size,
          :responses => responses.compact.size,
          :correct => responses.find_all(&:correct?).compact.size
        }
      end
      def mandatory_questions_complete?
        sections = survey.sections.includes(:questions)
        sections.each do |section|
          unless section_complete?(section)
            return false
          end
        end
        true
      end
      # def progress_hash
      #   qs = survey.sections_with_questions.map(&:questions).flatten
      #   ds = dependencies(qs.map(&:id))
      #   triggered = qs - ds.select{|d| !d.is_met?(self)}.map(&:question)
      #   { :questions => qs.compact.size,
      #     :triggered => triggered.compact.size,
      #     :triggered_mandatory => triggered.select{|q| q.mandatory?}.compact.size,
      #     :triggered_mandatory_completed => triggered.select{|q| q.mandatory? and is_answered?(q)}.compact.size
      #   }
      # end
      def section_complete?(section)
        section.questions.where(is_mandatory: true).where.not(display_type: 'label').each do |q|
          if q.triggered?(self) 
            if q.question_group.present? && q.question_group.display_type == "repeater"
              repeated_questions = section.questions.where(question_group_id: q.question_group.id).pluck(:id)
              rs = responses.where(question_id: repeated_questions).group_by(&:response_group)
              rs.keys.each do |group|
                repeated_questions.each do |question|
                  unless responses.exists?(response_group: group, question_id: question)
                    return false
                  end
                end
              end
            elsif is_unanswered?(q)
              return false
            end
          end
        end
        true
      end
      def is_answered?(question)
        !is_unanswered?(question)
      end
      def is_unanswered?(question)
        if %w(label image).include?(question.display_type)
          return false
        else
          rs = responses.where(question_id: question.id)
          if rs.none?
            return true
          end
        end
      end
      def is_group_unanswered?(group)
        puts "In is_group_unanswered?"
        group.questions.any?{|question| is_unanswered?(question)}
      end

      # Returns the number of response groups (count of group responses enterted) for this question group
      def count_group_responses(questions)
        questions.map { |q|
          responses.select { |r|
            (r.question_id.to_i == q.id.to_i) && !r.response_group.nil?
          }.group_by(&:response_group).size
        }.max
      end

      def unanswered_dependencies
        unanswered_question_dependencies + unanswered_question_group_dependencies
      end

      def unanswered_question_dependencies
        dependencies.select{ |d| d.question && self.is_unanswered?(d.question) && d.is_met?(self) }.map(&:question)
      end

      def unanswered_question_group_dependencies
        dependencies.
          select{ |d| d.question_group && self.is_group_unanswered?(d.question_group) && d.is_met?(self) }.
          map(&:question_group)
      end

      def all_dependencies(question_ids = nil)
        arr = dependencies(question_ids).partition{|d| d.is_met?(self) }
        {
          :show => arr[0].map{|d| d.question_group_id.nil? ? "q_#{d.question_id}" : "g_#{d.question_group_id}"},
          :hide => arr[1].map{|d| d.question_group_id.nil? ? "q_#{d.question_id}" : "g_#{d.question_group_id}"}
        }
      end

      # Check existence of responses to questions from a given survey_section
      def no_responses_for_section?(section)
        puts "In no_responses_for_section?"
        !responses.any?{|r| r.survey_section_id == section.id}
      end

      def update_from_ui_hash(ui_hash)
        transaction do
          ui_hash.each do |ord, response_hash|
            api_id = response_hash['api_id']
            fail "api_id missing from response #{ord}" unless api_id

            existing = Response.where(:api_id => api_id).first
            updateable_attributes = response_hash.reject { |k, v| k == 'api_id' }
            question_ref = Question.find(updateable_attributes["question_id"]).reference_identifier

                
            if self.class.has_blank_value?(response_hash)
              existing.destroy if existing
            elsif existing
              if existing.question_id.to_s != updateable_attributes['question_id']
                fail "Illegal attempt to change question for response #{api_id}."
              end
              if question_ref == "phq_date" || question_ref == "phq_dob"
                if updateable_attributes["string_value"] =~ /\A(?:0[1-9]|10|11|12)\/(?:0[1-9]|[1-2]\d|3[0-1])\/(?:(?:19|20)\d{2})\z/
                  existing.update(updateable_attributes)
                else
                  key = question_ref == "phq_date" ? :"today's date" : :date_of_birth
                  self.errors.add(key, "should be formatted as mm/dd/yyyy")
                end
              else
                existing.update(updateable_attributes)
              end
            else
              responses.build(updateable_attributes).tap do |r|
                r.api_id = api_id
                if question_ref == "phq_date" || question_ref == "phq_dob"
                  if updateable_attributes["string_value"] =~ /\A(?:0[1-9]|10|11|12)\/(?:0[1-9]|[1-2]\d|3[0-1])\/(?:(?:19|20)\d{2})\z/
                    r.save
                  else
                    key = question_ref == "phq_date" ? :"today's date" : :date_of_birth
                    self.errors.add(key, "should be formatted as mm/dd/yyyy")
                  end
                else
                  r.save
                end
              end
            end
          end
        end
      end

      protected

      def dependencies(question_ids = nil)
        question_ids = survey.sections.map(&:questions).flatten.map(&:id) if responses.blank? and question_ids.blank?
        deps = Dependency.includes(:dependency_conditions).
          where({:dependency_conditions => {:question_id => question_ids || responses.map(&:question_id)}})
        # this is a work around for a bug in active_record in rails 2.3 which incorrectly eager-loads associatins when a
        # condition clause includes an association limiter
        deps.each{|d| d.dependency_conditions.reload}
        deps
      end
    end
  end
end
