class Update < ActiveRecord::Base
  belongs_to :subscriber, :class_name => "User"
  belongs_to :resource, :polymorphic => true
  belongs_to :notifier, :polymorphic => true
  belongs_to :resource_owner, :class_name => "User"
  
  validates_uniqueness_of :notifier_id, :scope => [:notifier_type, :subscriber_id, :notification]
  
  before_create :set_resource_owner
  
  NOTIFICATIONS = %w(create change activity)
  
  named_scope :unviewed, :conditions => "viewed_at IS NULL"
  named_scope :activity, :conditions => {:notification => "activity"}
  named_scope :activity_on_my_stuff, :conditions => "resource_owner_id = subscriber_id AND notification = 'activity'"
  
  def set_resource_owner
    self.resource_owner = resource && resource.respond_to?(:user) ? resource.user : nil
  end
  
  def sort_by_date
    created_at || notifier.try(:created_at) || Time.now
  end
  
  def self.load_additional_activity_updates(updates)
    # fetch all other activity updates for the loaded resources
    activity_updates = updates.select{|u| u.notification == 'activity'}
    activity_update_ids = activity_updates.map{|u| u.id}
    activity_updates.each do |update|
      new_updates = Update.all(:conditions => [
        "subscriber_id = ? AND notification = 'activity' AND resource_type = ? AND resource_id = ? AND id NOT IN (?)",
        update.subscriber_id, update.resource_type, update.resource_id, activity_update_ids
      ])
      updates += new_updates
      activity_update_ids += new_updates.map{|u| u.id}
      activity_update_ids.uniq!
    end
    updates
  end
  
  def self.group_and_sort(updates, options = {})
    grouped_updates = []
    
    updates.group_by{|u| [u.resource_type, u.resource_id, u.notification]}.each do |key, batch|
      resource_type, resource_id, notification = key
      batch = batch.sort_by{|u| u.sort_by_date}
      if notification == "created_observations" && batch.size > 1
        batch.group_by{|u| u.created_at.strftime("%Y-%m-%d %H")}.each do |hour, hour_updates|
          grouped_updates << [key, hour_updates]
        end
      elsif notification == "activity" && !options[:skip_past_activity]
        # get the resource that has all this activity
        resource = Object.const_get(resource_type).find_by_id(resource_id)
        
        # get the associations on that resource that generate activity updates
        activity_assocs = resource.class.notifying_associations.select do |assoc, assoc_options|
          assoc_options[:notification] == "activity"
        end
        
        # create pseudo updates for all activity objects
        activity_assocs.each do |assoc, assoc_options|
          # this is going to lazy load assoc's of the associate (e.g. a comment's user) which might not be ideal
          resource.send(assoc).each do |associate|
            unless batch.detect{|u| u.notifier == associate}
              batch << Update.new(:resource => resource, :notifier => associate, :notification => "activity")
            end
          end
        end
        grouped_updates << [key, batch.sort_by{|u| u.sort_by_date}]
      else
        grouped_updates << [key, batch]
      end
    end
    grouped_updates.sort_by {|key, updates| updates.last.sort_by_date.to_i * -1}
  end
  
  def self.email_updates
    Rails.logger.info "[INFO #{Time.now}] start daily updates emailer"
    start_time = 1.day.ago.utc
    end_time = Time.now.utc
    email_count = 0
    user_ids = Update.all(
        :select => "DISTINCT subscriber_id",
        :conditions => ["created_at BETWEEN ? AND ?", start_time, end_time]).map{|u| u.subscriber_id}.compact
    user_ids.each do |subscriber_id|
      if email_updates_to_user(subscriber_id, start_time, end_time)
        email_count += 1
      end
    end
    Rails.logger.info "[INFO #{Time.now}] end daily updates emailer, sent #{email_count} in #{Time.now - end_time} s"
  end
  
  def self.email_updates_to_user(subscriber, start_time, end_time)
    user = User.find_by_id(subscriber.to_i) unless subscriber.is_a?(User)
    user ||= User.find_by_login(subscriber)
    return unless user
    return if user.email.blank?
    return unless user.active? # email verified
    return unless user.admin? # testing
    updates = Update.all(:conditions => ["subscriber_id = ? AND created_at BETWEEN ? AND ?", user.id, start_time, end_time])
    updates.delete_if do |u| 
      !user.prefers_comment_email_notification? && u.notifier_type == "Comment" ||
      !user.prefers_identification_email_notification? && u.notifier_type == "Identification"
    end.compact
    return if updates.blank?
    Emailer.deliver_updates_notification(user, updates)
    true
  end
  
  def self.eager_load_associates(updates, options = {})
    includes = options[:includes] || {
      :observation => [:user, {:taxon => :taxon_names}, :iconic_taxon, :photos],
      :identification => [:user, {:taxon => [:taxon_names, :photos]}, {:observation => :user}],
      :comment => [:user, :parent],
      :listed_taxon => [{:list => :user}, {:taxon => [:photos, :taxon_names]}]
    }
    update_cache = {}
    [Comment, Identification, Observation, ListedTaxon, Post, User].each do |klass|
      ids = []
      updates.each do |u|
        ids << u.notifier_id if u.notifier_type == klass.to_s
        ids << u.resource_id if u.resource_type == klass.to_s
      end
      ids = ids.compact.uniq
      next if ids.blank?
      update_cache[klass.to_s.underscore.pluralize.to_sym] = klass.all(
        :conditions => ["id IN (?)", ids], 
        :include => includes[klass.to_s.underscore.to_sym]
      ).index_by{|o| o.id}
    end
    update_cache[:users] ||= {}
    updates.each do |update|
      update_cache[:users][update.subscriber_id] = update.subscriber
      update_cache[:users][update.resource_owner_id] = update.resource_owner if update.resource_owner
    end
    update_cache
  end
  
  def self.user_viewed_updates(updates)
    # mark all as viewed
    Update.update_all(["viewed_at = ?", Time.now], ["id in (?)", updates])
    
    # delete PAST activity updates that were not in this batch
    update_ids = updates.map{|u| u.id}
    updates.each do |update|
      next unless update.notification == 'activity'
      Update.delete_all([
        "id < ? AND id NOT IN (?) AND subscriber_id = ? AND " + 
        "notification = 'activity' AND resource_type = ? AND resource_id = ?",
        update_ids.min,
        update_ids,
        update.subscriber_id,
        update.resource_type,
        update.resource_id
      ])
    end
    Update.delete_all(["subscriber_id = ? AND created_at < ?", updates.first.subscriber_id, 1.year.ago])
  end
end