Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    post "auth/register" => "auth#register"
    post "auth/login" => "auth#login"
    get "me/chats" => "me#chats"
    get "me/search/messages" => "me#search_messages"

    namespace :telegram do
      resources :chats, only: %i[index], controller: "chats"
      resources :sessions, only: %i[index create show destroy], controller: "sessions" do
        member do
          post :phone
          post :code
          post :password
          patch :watch_targets
          post :sync_chats
          post :sync_messages
        end
      end
    end
  end
end
