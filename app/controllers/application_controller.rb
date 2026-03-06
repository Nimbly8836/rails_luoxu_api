class ApplicationController < ActionController::API
  private

  def authenticate_system_user!
    token = bearer_token
    @current_system_user = SystemUser.find_by(api_token: token, active: true)
    return if @current_system_user

    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def current_system_user
    @current_system_user
  end

  def authenticate_admin!
    return if current_system_user&.admin?

    render json: { error: "Forbidden" }, status: :forbidden
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    return nil unless header.start_with?("Bearer ")

    header.split(" ", 2).last
  end
end
