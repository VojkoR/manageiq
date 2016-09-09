class ServiceOrchestration < Service
  include ServiceOrchestrationMixin
  include ServiceOrchestrationOptionsMixin

  # read from DB or parse from dialog
  def stack_name
    @stack_name ||= options.fetch_path(:orchestration_stack, 'name')
    @stack_name ||= options.fetch_path(:stack_name) # required only for backward compatibility purpose
    @stack_name ||= OptionConverter.get_stack_name(options[:dialog] || {})
  end

  # override existing stack name (most likely from dialog)
  def stack_name=(stname)
    @stack_name = stname
    options.store_path(:orchestration_stack, 'name', stname)
  end

  def stack_ems_ref
    orchestration_stack.try(:ems_ref)
  end
  Vmdb::Deprecation.deprecate_methods(ServiceOrchestration, :stack_ems_ref => "use orchestration_stack#ems_ref instead")

  def orchestration_stack_status
    return "check_status_failed", "stack has not been deployed" unless orchestration_stack

    orchestration_stack.raw_status.normalized_status
  rescue MiqException::MiqOrchestrationStackNotExistError, MiqException::MiqOrchestrationStatusError => err
    # naming convention requires status to end with "failed"
    ["check_status_failed", err.message]
  end

  def deploy_orchestration_stack
    @orchestration_stack = ManageIQ::Providers::CloudManager::OrchestrationStack.create_stack(
      orchestration_manager, stack_name, orchestration_template, stack_options)
  ensure
    # create options may never be saved before unless they were overridden
    save_create_options
  end

  def update_orchestration_stack
    # use orchestration_template from service_template, which may be different from existing orchestration_template
    orchestration_stack.raw_update_stack(service_template.orchestration_template, update_options)
  end

  def orchestration_stack
    @orchestration_stack ||= service_resources.find { |sr| sr.resource.kind_of?(OrchestrationStack) }.try(:resource)

    # ems_id is a good indication that the stack object can be reconstructed and connect to its provider
    if @orchestration_stack.nil? && options.fetch_path(:orchestration_stack, 'ems_id')
      @orchestration_stack = OrchestrationStack.new(options[:orchestration_stack])
    end
    @orchestration_stack
  end

  def build_stack_options_from_dialog(dialog_options)
    tenant_name = OptionConverter.get_tenant_name(dialog_options)
    tenant_option = tenant_name.blank? ? {} : {:tenant_name => tenant_name}

    converter = OptionConverter.get_converter(dialog_options || {}, orchestration_manager.class)
    converter.stack_create_options.merge(tenant_option)
  end

  def indirect_vms
    return [] if orchestration_stack.nil? || orchestration_stack.new_record?
    orchestration_stack.indirect_vms
  end

  def direct_vms
    return [] if orchestration_stack.nil? || orchestration_stack.new_record?
    orchestration_stack.direct_vms
  end

  def all_vms
    return [] if orchestration_stack.nil? || orchestration_stack.new_record?
    orchestration_stack.vms
  end

  # This is called when provision is completed and stack is added to VMDB through a refresh
  def post_provision_configure
    add_stack_to_resource

    assign_vms_owner
  end

  private

  def add_stack_to_resource
    @orchestration_stack = OrchestrationStack.find_by(
      :ems_ref => options.fetch_path(:orchestration_stack, 'ems_ref'),
      :ems_id  => options.fetch_path(:orchestration_stack, 'ems_id')
    )
    add_resource!(@orchestration_stack) if @orchestration_stack
  end

  def assign_vms_owner
    all_vms.each do |vm|
      vm.update_attributes(:evm_owner_id => evm_owner_id, :miq_group_id => miq_group_id)
    end
  end

  def build_stack_create_options
    # manager from dialog_options overrides the one copied from service_template
    dialog_options = options[:dialog] || {}
    manager_from_dialog = OptionConverter.get_manager(dialog_options)
    self.orchestration_manager = manager_from_dialog if manager_from_dialog
    raise _("orchestration manager was not set") if orchestration_manager.nil?

    # orchestration template from dialog_options overrides the one copied from service_template
    template_from_dialog = OptionConverter.get_template(dialog_options)
    self.orchestration_template = template_from_dialog if template_from_dialog

    build_stack_options_from_dialog(dialog_options)
  end

  def save_create_options
    stack_attributes = @orchestration_stack ?
                       @orchestration_stack.attributes.compact :
                       {:name => stack_name}
    stack_attributes.delete('id')
    options.merge!(:orchestration_stack => stack_attributes,
                   :create_options      => dup_and_process_password(stack_options))
    save!
  end
end
