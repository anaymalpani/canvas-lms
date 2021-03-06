class EnrollmentState < ActiveRecord::Base
  strong_params

  belongs_to :enrollment

  attr_accessor :skip_touch_user, :user_needs_touch, :is_direct_recalculation
  validates_presence_of :enrollment_id

  self.primary_key = 'enrollment_id'

  def hash
    global_enrollment_id.hash
  end

  def state_needs_recalculation?
    !self.state_is_current? || self.state_valid_until && self.state_valid_until < Time.now
  end

  def ensure_current_state
    Shackles.activate(:master) do
      self.recalculate_state if self.state_needs_recalculation?
      self.recalculate_access if !self.access_is_current?
      self.save! if self.changed?
    end
  end

  def get_effective_state
    self.ensure_current_state

    if restricted_access?
      :inactive
    elsif self.state == 'pending_invited'
      :invited
    elsif self.state == 'pending_active'
      :accepted
    else
      self.state.to_sym
    end
  end

  def get_display_state
    self.ensure_current_state

    if pending?
      :pending
    else
      self.state.to_sym
    end
  end

  def pending?
    %w{pending_active pending_invited}.include?(self.state)
  end

  def recalculate_state
    self.state_valid_until = nil
    self.state_started_at = nil

    wf_state = self.enrollment.workflow_state
    invited_or_active = %w{invited active}.include?(wf_state)

    if invited_or_active
      if self.enrollment.course.completed?
        self.state = 'completed'
      else
        self.calculate_state_based_on_dates
      end
    else
      self.state = wf_state
    end
    self.state_is_current = true

    if self.state_changed? && self.enrollment.view_restrictable?
      self.access_is_current = false
    end

    if self.state_changed? && (self.state == "active" || self.state_was == "active")
      # we could make this happen on every state change, to expire cached authorization right away but
      # the permissions cache expires within an hour anyway
      # this will at least prevent cached unauthorization
      self.user_needs_touch = true
      unless self.skip_touch_user
        self.enrollment.user.touch
      end
    end
  end

  def calculate_state_based_on_dates
    wf_state = self.enrollment.workflow_state
    ranges = self.enrollment.enrollment_dates
    now = Time.now

    # start_at <= now <= end_at, allowing for open ranges on either end
    if range = ranges.detect{|start_at, end_at| (start_at || now) <= now && now <= (end_at || now) }
      self.state = wf_state
      start_at, end_at = range
      self.state_started_at = start_at
      self.state_valid_until = end_at
    else
      global_start_at = ranges.map(&:compact).map(&:min).compact.min

      if !global_start_at
        # Not strictly within any range
        self.state = wf_state
      elsif global_start_at < now
        self.state_started_at = ranges.map(&:last).compact.min
        self.state = 'completed'
      elsif self.enrollment.fake_student? # Allow student view students to use the course before the term starts
        self.state = wf_state
      else
        self.state_valid_until = global_start_at
        if self.enrollment.view_restrictable?
          # these enrollment states mean they still can't participate yet even if they've accepted it,
          # but should be able to view just like an invited enrollment
          if wf_state == 'active'
            self.state = 'pending_active'
          else
            self.state = 'pending_invited'
          end
        else
          # admin user restricted by term dates
          self.state = 'inactive'
        end
      end
    end
  end

  def recalculate_access
    if self.enrollment.view_restrictable?
      self.restricted_access =
        case self.state
        when 'pending_invited', 'pending_active'
          self.enrollment.restrict_future_view?
        when 'completed'
          self.enrollment.restrict_past_view?
        else
          false
        end
    else
      self.restricted_access = false
    end
    self.access_is_current = true
  end

  def self.enrollments_needing_calculation(scope=Enrollment.all)
    scope.joins(:enrollment_state).
      where("enrollment_states.state_is_current = ? OR enrollment_states.access_is_current = ?", false, false)
  end

  def self.process_states_in_ranges(start_at, end_at, enrollment_scope=Enrollment.all)
    Enrollment.find_ids_in_ranges(:start_at => start_at, :end_at => end_at, :batch_size => 250) do |min_id, max_id|
      process_states_for(enrollments_needing_calculation(enrollment_scope).where(:id => min_id..max_id))
    end
  end

  def self.process_term_states_in_ranges(start_at, end_at, term, enrollment_type=nil)
    scope = term.enrollments
    scope = scope.where(:type => enrollment_type) if enrollment_type
    process_states_in_ranges(start_at, end_at, scope)
  end

  def self.process_account_states_in_ranges(start_at, end_at, account_ids)
    process_states_in_ranges(start_at, end_at, enrollments_for_account_ids(account_ids))
  end

  def self.process_states_for_ids(enrollment_ids)
    process_states_for(Enrollment.where(:id => enrollment_ids).to_a)
  end

  def self.process_states_for(enrollments)
    enrollments = Array(enrollments)
    Canvas::Builders::EnrollmentDateBuilder.preload(enrollments, false)

    enrollments.each do |enrollment|
      enrollment.enrollment_state.skip_touch_user = true
      update_enrollment(enrollment)
    end

    user_ids_to_touch = enrollments.select{|e| e.enrollment_state.user_needs_touch}.map(&:user_id)
    if user_ids_to_touch.any?
      Shard.partition_by_shard(user_ids_to_touch) do |sliced_user_ids|
        User.where(:id => sliced_user_ids).touch_all
      end
    end
  end

  def self.update_enrollment(enrollment)
    enrollment.enrollment_state.ensure_current_state
  end

  INVALIDATEABLE_STATES = %w{pending_invited pending_active invited active completed inactive}.freeze # don't worry about creation_pending or rejected, etc
  def self.invalidate_states(enrollment_scope)
    EnrollmentState.where(:enrollment_id => enrollment_scope, :state_is_current => true, :state => INVALIDATEABLE_STATES).update_all(:state_is_current => false)
  end

  def self.force_recalculation(enrollment_ids)
    if enrollment_ids.any?
      EnrollmentState.where(:enrollment_id => enrollment_ids, :state_is_current => true).update_all(:state_is_current => false)
      EnrollmentState.send_later_if_production(:process_states_for_ids, enrollment_ids)
    end
  end

  def self.invalidate_access(enrollment_scope, states_to_update)
    EnrollmentState.where(:enrollment_id => enrollment_scope, :access_is_current => true, :state => states_to_update).update_all(:access_is_current => false)
  end

  def self.enrollments_for_account_ids(account_ids)
    Enrollment.joins(:course).where(:courses => {:account_id => account_ids}).where(:type => %w{StudentEnrollment ObserverEnrollment})
  end

  ENROLLMENT_BATCH_SIZE = 1_000

  def self.invalidate_states_for_term(term, enrollment_type=nil)
    # invalidate and re-queue individual jobs for reprocessing because it might be too big to do all at once
    scope = term.enrollments
    scope = scope.where(:type => enrollment_type) if enrollment_type
    scope.find_ids_in_ranges(:batch_size => ENROLLMENT_BATCH_SIZE) do |min_id, max_id|
      if invalidate_states(scope.where(:id => min_id..max_id)) > 0
        EnrollmentState.send_later_if_production_enqueue_args(:process_term_states_in_ranges, {:priority => Delayed::LOW_PRIORITY}, min_id, max_id, term, enrollment_type)
      end
    end
  end

  def self.invalidate_states_for_course_or_section(course_or_section)
    scope = course_or_section.enrollments
    if invalidate_states(scope) > 0
      process_states_for(enrollments_needing_calculation(scope))
    end
  end

  def self.access_states_to_update(changed_keys)
    states_to_update = []
    # only need to invalidate access for future students if future access changed, etc
    states_to_update += ['pending_invited', 'pending_active'] if changed_keys.include?(:restrict_student_future_view)
    states_to_update += ['completed'] if changed_keys.include?(:restrict_student_past_view)
    states_to_update
  end

  def self.invalidate_access_for_accounts(account_ids, changed_keys)
    states_to_update = access_states_to_update(changed_keys)
    enrollments_for_account_ids(account_ids).find_ids_in_ranges(:batch_size => ENROLLMENT_BATCH_SIZE) do |min_id, max_id|
      scope = enrollments_for_account_ids(account_ids).where(:id => min_id..max_id)
      if invalidate_access(scope, states_to_update) > 0
        EnrollmentState.send_later_if_production_enqueue_args(:process_account_states_in_ranges, {:priority => Delayed::LOW_PRIORITY}, min_id, max_id, account_ids)
      end
    end
  end

  def self.invalidate_access_for_course(course, changed_keys)
    states_to_update = access_states_to_update(changed_keys)
    scope = course.enrollments.where(:type => %w{StudentEnrollment ObserverEnrollment})
    if invalidate_access(scope, states_to_update) > 0
      process_states_for(enrollments_needing_calculation(scope))
    end
  end

  def self.recalculate_expired_states
    while (enrollments = Enrollment.joins(:enrollment_state).where("enrollment_states.state_valid_until IS NOT NULL AND
           enrollment_states.state_valid_until < ?", Time.now.utc).limit(250).to_a) && enrollments.any?
      process_states_for(enrollments)
    end
  end
end